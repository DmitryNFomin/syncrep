# remote_write vs remote_apply: Exposing the Latency Delta

Benchmarks that demonstrate when and why `synchronous_commit = remote_apply`
adds visible latency compared to `remote_write`. Includes a Docker-based
two-node cluster for reproducible testing.


## Background: How Synchronous Replication Works

When a backend on the primary commits a transaction, PostgreSQL writes a WAL
(Write-Ahead Log) record and — when synchronous replication is configured —
waits for the standby to acknowledge receipt before returning success to the
client.  What exactly the primary waits for depends on `synchronous_commit`:

```
                         PRIMARY                              STANDBY
                         ───────                              ───────
  Client commits
       │
       ▼
  Write WAL to local disk
       │
       ▼
  Send WAL via walsender ──────────────────────► walreceiver receives WAL
       │                                              │
       │                                              ▼
       │                                         Write WAL to OS page cache
       │                                              │
       │◄─── remote_write ack ◄───────────────────────┤
       │                                              ▼
       │                                         Flush WAL to disk
       │                                              │
       │◄─── remote_flush ack ◄───────────────────────┤
       │                                              ▼
       │                                         Startup process replays WAL
       │                                         (single-threaded!)
       │                                              │
       │◄─── remote_apply ack ◄───────────────────────┘
       │
       ▼
  Return "COMMIT" to client
```

The critical insight: **WAL writing on the standby is cheap** (sequential
append to a file, handled by the walreceiver), but **WAL replay is expensive**
(random I/O into heap and index pages, handled by a single startup process).

With `remote_write`, the primary returns as soon as WAL bytes land in the
standby's OS page cache.  With `remote_apply`, it must wait for the single-
threaded startup process to actually replay those bytes — which involves
reading data pages, applying changes, updating indexes, and writing the
modified pages back.

**The delta between remote_write and remote_apply = the replay cost of the
committed transaction's WAL on the standby.**


## When the Delta Becomes Visible

Under light load, replay keeps up with writes and the delta is sub-millisecond
(essentially just the CPU time for replay on the standby).  The delta becomes
large in two situations:

### 1. Replay saturation (Scenarios 1, 3, 4, 5, 6)

The primary generates WAL across N parallel backends.  The standby replays
through ONE startup process.  If the WAL generation rate exceeds the replay
rate, a replay lag builds up.

- With `remote_write`: the primary doesn't care.  WAL is written to the
  standby's OS cache instantly; the primary returns.  Replay lag grows
  silently.

- With `remote_apply`: the primary's commit waits for replay.  Since replay
  is the bottleneck, TPS is clamped to the replay throughput.  Each
  transaction's latency = time waiting for the overloaded replay process.

What makes replay expensive:
- **Index maintenance**: each updated indexed column requires inserting a new
  index entry (btree traversal, possible page split).  With N indexes, one
  UPDATE generates ~(1 + N) WAL records, all replayed serially.
- **Random I/O**: index pages are scattered across disk.  If the standby's
  `shared_buffers` can't cache them, each index entry replay requires a
  random read.
- **Expression evaluation**: functional indexes (e.g., `hashtext(payload)`)
  require recomputing the expression during replay.
- **TOAST operations**: large values (>2KB) are stored out-of-line.  Replaying
  an UPDATE that changes a TOASTed column requires decompressing old chunks,
  allocating new ones, and writing multiple TOAST heap pages.
- **GIN pending list flushes**: GIN indexes buffer insertions in a "pending
  list" and flush in bulk.  Each flush generates a burst of WAL that requires
  posting tree traversal, page splits, and posting list compression on replay.

### 2. Replay blocking (Scenarios 2, 7, 8)

A query on the standby holds a MVCC snapshot.  If WAL replay needs to
physically remove row versions still visible to that snapshot (e.g., from
VACUUM), the startup process must either cancel the query or pause.

With `max_standby_streaming_delay = -1`, it pauses — and ALL replay stops,
not just for the conflicting relation.  This is because WAL replay is
sequential; it can't skip ahead.

- With `remote_write`: WAL is still written to the standby (walreceiver
  works independently of the startup process).  The primary is unaffected.

- With `remote_apply`: every committing transaction waits for replay that
  will never arrive (until the standby query finishes).  Result: total
  write freeze.


## Docker Test Setup

The included Docker setup creates two PostgreSQL 16 containers on the same
host, connected via synchronous streaming replication.

### Architecture

```
┌────────────────────────────────────────────┐
│  syncrep-primary (full resources)          │
│  shared_buffers = 256 MB                   │
│  synchronous_standby_names = '*'           │
│  port 15432                                │
└──────────────────┬─────────────────────────┘
                   │ streaming replication
                   │ (sync)
┌──────────────────▼─────────────────────────┐
│  syncrep-standby (constrained)             │
│  shared_buffers = 48 MB                    │
│  recovery_prefetch = off                   │
│  max_standby_streaming_delay = -1          │
│  hot_standby_feedback = off                │
│  CPU limit: 0.5 cores                      │
│  Memory limit: 384 MB                      │
│  port 15433                                │
└────────────────────────────────────────────┘
```

### Why Constrain the Standby

On a single machine, both containers share the same CPU, RAM, and disk.
Without constraints, the single-threaded replay keeps up because:
- The OS page cache (gigabytes of RAM) acts as a transparent L2 cache,
  masking the effect of small `shared_buffers`.
- The replay process gets a full CPU core and fast SSD I/O.

In production, the standby is often a different (sometimes weaker) machine.
The constraints simulate this asymmetry:

| Knob | Value | Why |
|------|-------|-----|
| `shared_buffers` | 48 MB | Working set (3+ GB) doesn't fit; every replayed index page is a cache miss |
| `recovery_prefetch` | off | Prevents read-ahead during replay; every I/O is synchronous |
| `cpus` (Docker) | 0.5 | The single-threaded startup process gets half a core; combined with I/O waits, this cuts replay throughput dramatically |
| `memory` (Docker) | 384 MB | Limits the OS page cache (384 MB total minus postgres processes); the 3+ GB working set causes constant evictions |
| `hot_standby_feedback` | off | (Scenario 2) Prevents the standby from holding back VACUUM on the primary, which is required for the conflict |
| `max_standby_streaming_delay` | -1 | (Scenario 2) Pauses replay on conflict instead of canceling the query |

**On real hardware**, you get the same effect naturally when:
- The standby has less RAM than the primary (common in read-replica configs)
- The standby uses slower disks (spinning rust vs. NVMe)
- Cross-datacenter replication adds network latency to each WAL round-trip
- The standby runs read queries that consume CPU/IO alongside replay

### Startup

```bash
# Requires: docker compose v2
docker compose -f docker/docker-compose.yml up -d

# Or automated (includes all scenarios):
bash validate.sh
```

### Docker Pitfall: Init Deadlock

`synchronous_standby_names` CANNOT be in the primary's command-line args.
The Docker entrypoint starts a temporary postgres instance for `initdb` /
`CREATE DATABASE` before the standby connects.  With `sync_standby_names='*'`
and no standby, every WAL-writing DDL deadlocks waiting for a sync standby.

Solution: set via `ALTER SYSTEM` in `docker/primary/init.sh`, which writes to
`postgresql.auto.conf`.  The setting only takes effect when the real server
starts (after init), by which time the standby connects.


## Scenario 1: Index-Heavy UPDATE Saturation

**Goal**: Make the replay process fall behind by generating more WAL per second
(across parallel backends) than one startup process can replay.

### Schema

```sql
CREATE TABLE idx_heavy (
    id      integer PRIMARY KEY,
    acct_id integer NOT NULL,
    val1    integer NOT NULL,
    val2    integer NOT NULL,
    val3    integer NOT NULL,
    val4    integer NOT NULL,
    val5    integer NOT NULL,
    val6    integer NOT NULL,
    status  smallint NOT NULL DEFAULT 0,
    payload text NOT NULL DEFAULT ''
) WITH (fillfactor = 50);
```

**`fillfactor = 50`**: Each 8 KB heap page is only filled to 50%.  This
doubles the number of heap pages, spreading rows across more blocks.  At
48 MB `shared_buffers`, far fewer pages are cached; most replay I/O hits
disk (or at best the memory-limited OS page cache).

### Indexes (16 total: PK + 15 secondary)

```
Per-column (8):  acct_id, val1, val2, val3, val4, val5, val6, status
Composite  (4):  (acct_id, status, val1)
                 (status, val4, val5)
                 (val1, val2, val3, val4)
                 (val5, val6, status, acct_id)
Functional (3):  abs(val1 - val2)
                 (val3 + val4 + val5)
                 hashtext(payload)
```

Each UPDATE changes val1-val6 and status.  Since ALL indexed columns change,
every secondary index must insert a new entry AND eventually remove the old
one.  HOT (Heap-Only Tuple) updates are impossible because the indexed
columns change.

### What Happens During Replay of One UPDATE

The startup process must:
1. Read the target heap page (random I/O if not cached)
2. Apply the heap UPDATE (write new tuple version)
3. For each of 15 secondary indexes:
   a. Locate the old index entry's btree leaf page (random read)
   b. Mark it for deletion
   c. Find the insertion point for the new key (random read, possibly a
      different page)
   d. Insert the new index entry (write, possible page split)
4. For the 3 functional indexes: recompute the expression first

That's ~30+ random I/O operations per UPDATE, all serialized through one
process.  On the primary, 32 backends do this in parallel.

### Data

2,000,000 rows.  With `fillfactor=50` and 16 indexes, total on-disk size is
~3-4 GB — far exceeding the standby's 48 MB shared_buffers + 300 MB available
OS page cache.

### Workload

```sql
-- pgbench script (one txn per iteration)
\set id random(1, 2000000)
\set v1 random(1, 1000000)
...
UPDATE idx_heavy
   SET val1 = :v1, val2 = :v2, val3 = :v3,
       val4 = :v4, val5 = :v5, val6 = :v6,
       status = :st
 WHERE id = :id;
```

Random key selection ensures the touched pages are scattered, maximizing cache
misses on the standby.

### Running

```bash
# On primary (or via docker exec):
psql -c "ALTER SYSTEM SET synchronous_commit = 'remote_write';"
psql -c "SELECT pg_reload_conf();"
psql -c "CHECKPOINT;"
pgbench -f scenario1_saturate_indexes/workload.sql \
    -c 32 -j 8 -T 45 -P 5 --no-vacuum bench

# Then repeat with:
psql -c "ALTER SYSTEM SET synchronous_commit = 'remote_apply';"
psql -c "SELECT pg_reload_conf();"
```

### What to Expect

| Mode | Behavior |
|------|----------|
| `remote_write` | Full primary throughput (~3000+ TPS). Replay lag grows silently (1+ GB in 45s). |
| `remote_apply` | TPS clamped to replay throughput (~300-400 TPS). Each commit waits 80-100ms for replay. |

### Docker-Validated Results (constrained standby: 0.5 CPU, 384 MB RAM)

```
                remote_write    remote_apply    ratio
avg latency     9.8 ms          87.2 ms         8.9x
TPS             3250            367             8.9x
```

### Real Hardware Results (identical VMs: 4 CPU, 7.6 GB RAM, PG 17)

```
                remote_write    remote_apply    ratio
avg latency     8.3 ms          9.9 ms          1.2x
TPS             3857            3228            1.2x
```

With identical hardware, the standby's single-threaded replay keeps up — the
4-core/7.6 GB standby has enough resources to replay 16-index UPDATEs at near
primary speed.  To see a bigger gap, the standby needs less RAM (so index pages
don't fit in cache) or slower disks.

### Tuning for Your Hardware

- **Wider gap**: reduce standby `shared_buffers`, add more indexes, use
  `fillfactor = 30`, increase pgbench clients
- **Narrower gap**: give the standby more RAM, enable `recovery_prefetch`,
  use fewer indexes, reduce client count
- **On bare metal**: if both machines have similar fast NVMe, you may need
  40+ clients and 20+ indexes.  If the standby has spinning disks, even
  10 indexes will show a dramatic gap.


## Scenario 2: Blocked Replay via Standby Query Conflict

**Goal**: Completely stop WAL replay on the standby using a long-running query,
then show that `remote_write` is unaffected while `remote_apply` freezes.

### The Conflict Mechanism (PostgreSQL Internals)

PostgreSQL uses MVCC: `DELETE` marks rows dead (sets `xmax`) but doesn't
remove them.  `VACUUM` physically removes dead row versions.  On the standby:

1. A `REPEATABLE READ` query takes a snapshot at time T1.  It can see all row
   versions visible at T1 — including rows that will later be deleted.

2. On the primary, rows are deleted (T2 > T1) and then vacuumed (T3 > T2).
   VACUUM generates `XLOG_HEAP2_PRUNE` WAL records that physically remove
   the dead tuples from heap pages.

3. The standby receives the PRUNE WAL.  The startup process tries to replay
   it — but the query from step 1 still needs those row versions (its
   snapshot predates the delete).  Removing them would break the query.

4. With `max_standby_streaming_delay = -1`, the startup process **pauses
   instead of canceling the query**.  Since WAL replay is sequential, ALL
   replay stops — not just for the affected table.

5. The walreceiver continues writing incoming WAL to files (it's independent
   of the startup process).  So `remote_write` acknowledgments keep flowing.
   But `remote_apply` acknowledgments stop.

### Critical Configuration

| Setting | Value | Why |
|---------|-------|-----|
| `max_standby_streaming_delay` | `-1` | Never cancel standby queries; pause replay instead |
| `hot_standby_feedback` | `off` | **Critical**: if `on`, the standby reports its oldest xmin to the primary, and the primary's VACUUM will NOT remove tuples the standby still needs — so no conflict ever occurs |

### Schema

```sql
CREATE TABLE orders (
    id          serial PRIMARY KEY,
    customer_id integer NOT NULL,
    amount      numeric(12,2) NOT NULL,
    status      text NOT NULL DEFAULT 'pending',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
-- 500,000 rows, 3 secondary indexes
```

### Step-by-Step Execution

**Phase 1**: Establish the conflict

```bash
# 1. On the STANDBY: start a long-running REPEATABLE READ query
#    This takes a snapshot and holds it for 70 seconds.
psql -h standby -d bench <<'SQL'
  BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
  SELECT count(*) FROM orders WHERE status = 'delivered';
  SELECT pg_sleep(70);
  COMMIT;
SQL

# 2. On the PRIMARY: create dead tuples AFTER the standby's snapshot
#    Use synchronous_commit=local to avoid deadlocking ourselves
#    (if remote_apply is set, our DELETE would wait for replay that's
#    about to be blocked).
psql -h primary -d bench \
  -c "SET synchronous_commit TO local" \
  -c "DELETE FROM orders WHERE id IN (
        SELECT id FROM orders
        WHERE status IN ('delivered','cancelled')
        ORDER BY id LIMIT 50000)"

# 3. On the PRIMARY: VACUUM to generate the conflicting WAL
#    Again with local commit — VACUUM's own WAL would deadlock under
#    remote_apply since replay is blocked.
psql -h primary -d bench \
  -c "SET synchronous_commit TO local" \
  -c "VACUUM orders"
```

**Why `synchronous_commit = local` for DELETE and VACUUM**:

Under `remote_apply`, the primary waits for the standby to replay each
transaction's WAL.  But VACUUM's WAL is precisely what BLOCKS replay (it
conflicts with the standby query).  If VACUUM waits for its own WAL to be
replayed, and replay is blocked by VACUUM's WAL, we have a deadlock.

Using `SET synchronous_commit TO local` at the session level makes the DELETE
and VACUUM commit locally without waiting for the standby.  Their WAL is
still sent and causes the conflict — but the primary sessions don't block.

**Phase 2**: Run the benchmark

```bash
# Set the test mode
psql -h primary -d bench \
  -c "ALTER SYSTEM SET synchronous_commit = 'remote_apply';"
  -c "SELECT pg_reload_conf();"

# Run pgbench — new sessions inherit the system-level setting
pgbench -h primary -d bench \
  -f scenario2_blocked_conflict/workload_steady.sql \
  -c 8 -j 4 -T 30 -P 5
```

The workload is deliberately lightweight (single-column status UPDATE) to
show that even trivial transactions stall when replay is blocked.

### What to Expect

| Mode | Behavior |
|------|----------|
| `remote_write` | Normal latency (~0.3-0.5ms). Replay lag grows but the primary doesn't notice. |
| `remote_apply` | **0 TPS** for the duration of the standby query. Transactions hang until replay resumes. |

### Docker-Validated Results (constrained standby)

```
                remote_write    remote_apply    ratio
avg latency     0.37 ms         2304 ms         6,200x
TPS             21,668          3.5             6,200x
```

### Real Hardware Results (identical VMs: 4 CPU, 7.6 GB RAM, PG 17)

```
                remote_write    remote_apply    ratio
avg latency     0.26 ms         861 ms          3,273x
TPS             30,368          9.3             3,273x
```

The mechanism is hardware-independent — replay blocking produces massive ratios
regardless of standby resources.

The progress lines tell the full story:
```
# remote_write: steady 20k+ TPS
progress: ... 20497.7 tps, lat 0.387 ms stddev 0.436, 0 failed
progress: ... 22454.2 tps, lat 0.353 ms stddev 0.416, 0 failed

# remote_apply: total freeze after first batch
progress: ... 43.2 tps, lat 0.308 ms ...   ← a few txns snuck in before conflict
progress: ... 0.0 tps, lat 0.000 ms ...    ← replay blocked
progress: ... 0.0 tps, lat 0.000 ms ...
progress: ... 0.0 tps, lat 0.000 ms ...    ← frozen for 55 seconds
```

### Real-World Relevance

This is the "Monday morning analytics query kills production writes" scenario.
It happens when:
- Read replicas run reporting queries (common use case for replication)
- `hot_standby_feedback = off` (the recommended default for not bloating the
  primary's tables)
- `max_standby_streaming_delay = -1` or a large value (to avoid canceling
  business-critical reports)
- `synchronous_commit = remote_apply` (for read-your-writes consistency)

The fix in production is usually one of:
- Use `remote_write` instead of `remote_apply` (accept slightly stale reads)
- Set `max_standby_streaming_delay` to a bounded value (cancel long queries)
- Use `hot_standby_feedback = on` (accept table bloat on primary)
- Run analytics queries on an asynchronous replica, not the sync standby


## Scenario 3: GIN + TOAST Bursty Replay Pressure

**Goal**: Show replay latency spikes caused by GIN index pending list flushes
and TOAST chunk I/O.

### GIN Internals That Matter

GIN (Generalized Inverted Index) stores a mapping from keys (e.g., lexemes,
trigrams, JSON paths) to sets of heap row pointers.  The internal structure is
a B-tree of key entries, where each entry points to a "posting tree" or
"posting list" of row TIDs.

To avoid the overhead of updating the posting tree on every INSERT, GIN uses
**fastupdate**: new entries are appended to a flat "pending list" page.  When
the pending list exceeds `gin_pending_list_limit`, it is flushed: all pending
entries are merged into the main GIN structure.  This flush:
- Reads and decompresses existing posting lists
- Inserts new TIDs (maintaining sort order)
- Recompresses and writes posting lists back
- May split posting tree pages

All of this generates a burst of WAL that is expensive to replay because the
startup process must repeat the same posting tree operations.

### TOAST Internals That Matter

Values larger than ~2 KB are stored out-of-line in a TOAST table.  Each value
is split into ~2 KB chunks, optionally compressed.  When replaying an UPDATE
that changes a TOASTed column:
1. The old TOAST chunks must be freed (mark dead, update TOAST index)
2. The new value must be compressed and split into chunks
3. Each chunk is inserted into the TOAST heap + TOAST index
4. The main heap tuple is updated with a pointer to the new TOAST data

A 20 KB body = ~10 TOAST chunks = ~20 WAL records just for the TOAST part.

### Schema

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE tickets (
    id          serial PRIMARY KEY,
    project_id  integer NOT NULL,
    title       text NOT NULL,
    body        text NOT NULL,           -- 10-30 KB → heavily TOASTed
    metadata    jsonb NOT NULL,          -- ~2 KB → TOASTed
    body_tsv    tsvector NOT NULL,
    tags        text[] NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- 4 GIN indexes
CREATE INDEX tickets_body_gin   ON tickets USING gin (body_tsv);
CREATE INDEX tickets_tags_gin   ON tickets USING gin (tags);
CREATE INDEX tickets_meta_gin   ON tickets USING gin (metadata jsonb_path_ops);
CREATE INDEX tickets_title_trgm ON tickets USING gin (title gin_trgm_ops);

-- Aggressive flush: 64 KB pending list (default is 4 MB since PG 14)
ALTER INDEX tickets_body_gin   SET (gin_pending_list_limit = 64);
ALTER INDEX tickets_tags_gin   SET (gin_pending_list_limit = 64);
ALTER INDEX tickets_meta_gin   SET (gin_pending_list_limit = 64);
ALTER INDEX tickets_title_trgm SET (gin_pending_list_limit = 64);
```

**`pg_trgm` GIN on `title`**: This is the most expensive GIN index to
maintain.  Each title is decomposed into overlapping 3-character substrings
(trigrams).  A 40-character title produces ~38 trigrams, each requiring a
posting tree insertion.  On replay, all 38 are replayed serially.

**`gin_pending_list_limit = 64`**: Forces frequent flushes (every 64 KB of
pending data vs. the default 4 MB).  Each flush generates a WAL burst.
With 4 GIN indexes flushing independently, the standby sees near-constant
GIN replay pressure.

### Data

300,000 rows.  Bodies are 10-30 KB (10-15 TOAST chunks each).  JSONB metadata
is ~2 KB.  Total table size with TOAST and GIN indexes: ~15 GB.

### Workload

Mixed: 70% INSERT (new tickets with large bodies) / 30% UPDATE (rewrite body
+ metadata on existing tickets).  12 concurrent clients.  Weights are set via
pgbench's `-f script.sql@N` syntax (e.g., `workload_insert.sql@7`,
`workload_update.sql@3`).

### What to Expect

| Mode | Behavior |
|------|----------|
| `remote_write` | Full primary throughput. Periodic replay lag spikes when GIN flushes. |
| `remote_apply` | ~1.5-2x higher latency. TPS limited by TOAST I/O + GIN flush replay speed. |

### Docker-Validated Results (constrained standby)

```
                remote_write    remote_apply    ratio
avg latency     8.0 ms          14.3 ms         1.8x
TPS             1490            840             1.8x
```

### Real Hardware Results (identical VMs: 4 CPU, 7.6 GB RAM, PG 17)

```
                remote_write    remote_apply    ratio
avg latency     4.2 ms          8.8 ms          2.1x
TPS             2825            1367            2.1x
```

Same 2.1x ratio on real hardware — GIN flush replay is expensive even with
ample resources because each flush requires posting tree traversal and
recompression, all serialized through the single startup process.

### Why 1.8-2.1x, Not More?

GIN fastupdate defers most of the expensive work to flush time.  Between
flushes, each INSERT only appends to the pending list (cheap, sequential).
The 1.8x ratio is the average including flush spikes.  Look at the per-5s
progress lines for the bursty pattern — some intervals show 2-3x latency
when a flush aligns with the measurement window.

To make the gap wider: disable `fastupdate` entirely (`SET (fastupdate = off)`).
This forces every INSERT to update the posting tree immediately, making
each replay record individually expensive.  But this is unrealistic for
production use.


## Scenario 4: Schema Migration (UPDATE + CREATE INDEX)

**Goal**: Show that a realistic schema migration — bulk UPDATE of 2M rows plus
index creation — generates a WAL burst that overwhelms the standby's replay,
stalling `remote_apply` commits to other tables.

### Why This Works

A common migration pattern: update a column across all rows, then add indexes.
The UPDATE rewrites every tuple (2M new row versions + WAL records), generating
~1 GB of WAL in a single burst.  The subsequent CREATE INDEX adds another
~200-400 MB.  The standby must replay this serially through one startup process.

While the standby is processing migration WAL, `remote_apply` commits to a
separate probe table stall because the replay LSN hasn't advanced past their
commit records yet.  `remote_write` commits return immediately — the WAL bytes
are written to the standby's OS cache by the walreceiver (independent of replay).

### Schema

```sql
CREATE TABLE events (
    id          bigserial PRIMARY KEY,
    ts          timestamptz NOT NULL,
    user_id     integer     NOT NULL,
    service     text        NOT NULL,
    duration_ms integer     NOT NULL,
    payload     text        NOT NULL   -- ~100 bytes (3× md5 hashes)
);
-- 2M rows, ~400 MB heap, NO secondary indexes at setup time
-- Indexes are created as part of the migration (the test)

CREATE TABLE probe_s4 (
    id  serial PRIMARY KEY,
    val integer NOT NULL DEFAULT 0,
    ts  timestamptz NOT NULL DEFAULT now()
);
-- 10K rows — tiny table for measuring commit latency
```

### Step-by-Step Execution

1. **Probe pgbench starts** (8 clients, 30s, UPDATE probe_s4)
2. **5s baseline** — both modes show ~5000+ TPS
3. **Migration fires** (with `synchronous_commit = local`):
   - `UPDATE events SET payload = upper(payload)` — rewrites all 2M rows
   - `CREATE INDEX events_ts_user ON events(ts, user_id)`
   - `CREATE INDEX events_svc_dur ON events(service, duration_ms)`
4. Probe continues measuring until 30s timer expires

The migration uses `synchronous_commit = local` to avoid deadlocking itself
(under `remote_apply`, the migration's own commits would wait for replay of
the very WAL that's overwhelming the standby).

### What to Expect

| Mode | Behavior |
|------|----------|
| `remote_write` | Brief TPS dip during UPDATE (primary I/O contention), then recovery. Average ~1600 TPS. |
| `remote_apply` | TPS drops to 0 for 15-20s while standby replays migration WAL. Average ~750 TPS. |

### Docker-Validated Results (constrained standby)

```
                remote_write    remote_apply    ratio
avg latency     4.9 ms          10.7 ms         2.2x
TPS             1642            749             2.2x
```

### Real Hardware Results (identical VMs: 4 CPU, 7.6 GB RAM, PG 17)

```
                remote_write    remote_apply    ratio
avg latency     1.8 ms          4.6 ms          2.5x
TPS             4352            1751            2.5x
```

Even with identical hardware, the migration generates enough WAL (~1 GB burst
from UPDATE) to overwhelm single-threaded replay. The ratio is slightly higher
than Docker because real hardware has no shared I/O contention — `remote_write`
runs at full speed while `remote_apply` stalls.

The per-5s progress lines tell the story:
```
# remote_write: dip during UPDATE, then recovery
progress: ... 6660.0 tps, lat 1.195 ms ...   ← baseline
progress: ...  225.0 tps, lat 35.1 ms ...    ← UPDATE running (primary I/O)
progress: ...   24.0 tps, lat 300.9 ms ...   ← UPDATE + index creation
progress: ... 1327.6 tps, lat 6.3 ms ...     ← recovering
progress: ... 1346.6 tps, lat 5.9 ms ...

# remote_apply: complete freeze during migration
progress: ... 4980.6 tps, lat 1.6 ms ...     ← baseline
progress: ...  189.6 tps, lat 39.0 ms ...    ← UPDATE starting
progress: ...    0.0 tps ...                  ← frozen (replay lag)
progress: ...    1.6 tps, lat 7287 ms ...     ← one txn squeezed through
progress: ...    0.0 tps ...                  ← frozen
progress: ...    0.0 tps ...                  ← still frozen
```

### Real-World Relevance

This is the "deploy a migration during business hours" scenario.  ORMs like
Rails/Django frequently generate `UPDATE ... SET column = expression` followed
by `ADD INDEX`.  With `remote_apply`, the migration silently freezes all OLTP
writes for the duration of replay — even writes to completely unrelated tables.


## Scenario 5: Bulk INSERT into Indexed Table (ETL)

**Goal**: Show that a bulk data load (INSERT...SELECT 2M rows) into a table
with 4 indexes generates enough WAL to saturate the standby's replay for the
full duration of the load.

### Why This Works

ETL pipelines, data imports, and batch jobs commonly load large datasets into
tables that already have production indexes.  Each inserted row generates WAL
for:
- 1 heap INSERT (~100 bytes)
- 4 index inserts (~50-100 bytes each)
- = ~500 bytes of WAL per row
- × 2M rows = ~1 GB of WAL

The primary writes this sequentially (fast).  The standby replays each row
serially — heap insert, then 4 index inserts with random I/O into btree
pages.  With 48 MB `shared_buffers`, most index pages are cache misses.

### Schema

```sql
CREATE TABLE logs (
    id      bigserial PRIMARY KEY,
    ts      timestamptz NOT NULL,
    level   text        NOT NULL,
    service text        NOT NULL,
    message text        NOT NULL,   -- ~130 bytes
    trace_id text       NOT NULL    -- 32-byte md5 hash
);

CREATE INDEX logs_ts         ON logs(ts);
CREATE INDEX logs_service_ts ON logs(service, ts);
CREATE INDEX logs_level_ts   ON logs(level, ts);
CREATE INDEX logs_trace      ON logs(trace_id);
```

### Step-by-Step Execution

1. **Probe pgbench starts** (8 clients, 60s, UPDATE probe_s5)
2. **2s baseline** — both modes show ~3000+ TPS
3. **Bulk load fires** (with `synchronous_commit = local`):
   ```sql
   INSERT INTO logs (ts, level, service, message, trace_id)
   SELECT ... FROM generate_series(1, 2000000);
   ```
4. Probe continues measuring for the remaining ~58s

### What to Expect

| Mode | Behavior |
|------|----------|
| `remote_write` | TPS drops to ~800-1000 during bulk load (primary I/O contention from index maintenance), but never freezes. |
| `remote_apply` | TPS degrades progressively to 0 as replay lag builds, stays frozen for 30-40s. |

### Docker-Validated Results (constrained standby)

```
                remote_write    remote_apply    ratio
avg latency     6.7 ms          42.1 ms         6.3x
TPS             1191            190             6.3x
```

### Real Hardware Results (identical VMs: 4 CPU, 7.6 GB RAM, PG 17)

```
                remote_write    remote_apply    ratio
avg latency     1.8 ms          5.3 ms          2.9x
TPS             4359            1505            2.9x
```

The ratio is lower than Docker (2.9x vs 6.3x) because the well-resourced
standby replays index inserts faster.  But single-threaded replay still can't
keep up with 2M rows × 4 indexes at primary speed.

The per-5s progress lines show the progressive degradation under `remote_apply`:
```
# remote_write: sustained ~900 TPS during load
progress: ... 3642.1 tps ...   ← baseline
progress: ... 1044.0 tps ...   ← load running
progress: ...  827.4 tps ...
progress: ...  937.4 tps ...   ← steady during load
progress: ... 1169.7 tps ...   ← load finishing

# remote_apply: progressive collapse to zero
progress: ... 2114.9 tps ...   ← baseline
progress: ...  571.0 tps ...   ← replay starting to lag
progress: ...  275.8 tps ...   ← lag growing
progress: ...    9.6 tps ...   ← nearly frozen
progress: ...    4.8 tps ...
progress: ...    0.0 tps ...   ← completely frozen
progress: ...    0.0 tps ...   ← frozen for 40+ seconds
```

### Real-World Relevance

This is the "nightly ETL job kills daytime OLTP" scenario.  Any bulk data load
into an indexed table generates this pattern.  Common triggers:
- Data warehouse imports
- Batch processing results written back to OLTP tables
- `pg_restore` of large tables
- `INSERT INTO ... SELECT` from staging tables


## Scenario 6: Full Page Image (FPI) Storm

**Goal**: Show that frequent checkpoints combined with scattered writes cause
massive WAL amplification via Full Page Images, overwhelming the standby's
replay capacity.

### The FPI Mechanism (PostgreSQL Internals)

PostgreSQL uses `full_page_writes = on` (the default) for torn-page protection.
After each checkpoint, the **first modification** to any data page writes the
entire 8 KB page into WAL instead of just the ~100-200 byte delta.  This
guarantees crash recovery can reconstruct the page from the WAL image.

With `checkpoint_timeout = 30s` and random scattered UPDATEs across a 2M-row
table, the vast majority of pages are "cold" (unmodified since last checkpoint)
when touched.  Each UPDATE generates:
- 8 KB heap FPI (instead of ~200 B delta)
- 8 KB index FPI per touched index page
- = 16-24 KB of WAL per UPDATE instead of ~400 B
- = **40-60x WAL amplification**

### Schema

```sql
CREATE TABLE wide_table (
    id       integer PRIMARY KEY,
    counter  integer NOT NULL DEFAULT 0,
    padding1 text    NOT NULL,   -- 200 bytes
    padding2 text    NOT NULL    -- 200 bytes
) WITH (fillfactor = 50);
-- 2M rows, ~9 rows per page → 220K pages → 1.7 GB heap
-- fillfactor=50 doubles page count, maximizing FPI generation

CREATE INDEX wide_counter_idx ON wide_table(counter);
```

**`fillfactor = 50`**: Each 8 KB page is only 50% full.  This doubles the
number of heap pages, meaning more pages to generate FPIs for.  With 220K+
pages and the standby's 48 MB shared_buffers, nearly every replayed FPI is
a cache miss.

### Workload

24 concurrent clients running random scattered UPDATEs:
```sql
\set id random(1, 2000000)
UPDATE wide_table SET counter = counter + 1 WHERE id = :id;
```

Each UPDATE touches a different random page, maximizing the chance that the
page is cold (unmodified since last checkpoint) and triggers an FPI.

### What to Expect

| Mode | Behavior |
|------|----------|
| `remote_write` | Full throughput. Periodic TPS dip right after each checkpoint (when all pages are cold). ~4700 TPS average. |
| `remote_apply` | ~2200 TPS average. First 15-20s show near-zero TPS (standby catching up after checkpoint), then partial recovery. |

### Docker-Validated Results (constrained standby)

```
                remote_write    remote_apply    ratio
avg latency     5.1 ms          10.9 ms         2.1x
TPS             4684            2197            2.1x
```

### Real Hardware Results (identical VMs: 4 CPU, 7.6 GB RAM, PG 17)

```
                remote_write    remote_apply    ratio
avg latency     3.4 ms          4.8 ms          1.4x
TPS             7148            5049            1.4x
```

Lower ratio on identical hardware — the standby has enough RAM and CPU to
replay FPIs quickly.  With a weaker standby (less RAM, slower disks), the
ratio approaches the Docker result.

The per-5s progress lines show the checkpoint effect:
```
# remote_write: dip after checkpoint, then full speed
progress: ... 1655.6 tps ...   ← right after checkpoint (all pages cold)
progress: ... 1528.8 tps ...   ← FPIs still heavy
progress: ... 3349.6 tps ...   ← warming up
progress: ... 4771.0 tps ...   ← most pages now hot
progress: ... 6637.8 tps ...   ← full speed

# remote_apply: extended freeze after checkpoint
progress: ...    0.0 tps ...   ← replay can't keep up with FPI flood
progress: ...    0.0 tps ...
progress: ...    0.0 tps ...
progress: ...    4.8 tps, lat 18296 ms ...   ← one txn trickled through
progress: ...  824.2 tps ...   ← replay catching up
progress: ... 4045.8 tps ...   ← recovered
```

### Why 2.1x, Not More?

FPI amplification is worst right after a checkpoint (when all pages are cold)
and decreases as more pages become "hot" (already modified since the last
checkpoint).  With `checkpoint_timeout = 30s`, the first ~15s after each
checkpoint show extreme FPI rates, but the second half shows near-normal WAL
sizes.  The 2.1x ratio is the average across both phases.

### Tuning

- **Wider gap**: shorter `checkpoint_timeout` (e.g., 15s), more clients, wider
  table (add more padding columns), smaller `fillfactor`
- **Narrower gap**: longer `checkpoint_timeout`, fewer clients, higher
  `fillfactor`, give the standby more resources


## Scenario 7: Reporting Query Blocks Replay (Cross-Table)

**Goal**: Show that a standby analytics query on one table can freeze writes to
a completely different table under `remote_apply` — demonstrating that WAL
replay blocking is **global**, not per-table.

### The Cross-Table Blocking Mechanism

This builds on Scenario 2's conflict mechanism but demonstrates a more insidious
effect: the standby query reads table A (`orders`), but the write freeze affects
table B (`probe_s7`).  This happens because:

1. A `REPEATABLE READ` query on the standby takes a snapshot and reads `orders`
2. On the primary, order churn (DELETE + INSERT) creates dead tuples in `orders`
3. `VACUUM orders` generates `XLOG_HEAP2_PRUNE` WAL records
4. The standby startup process tries to replay the PRUNE WAL but the query's
   snapshot still needs those rows → **replay pauses**
5. Since WAL replay is **sequential** (single process, single stream), ALL
   replay stops — not just for `orders`
6. Commits to `probe_s7` (a completely separate table) also wait for replay
   under `remote_apply`

This is the key insight: **one slow standby query on one table can freeze writes
to every table in the database**.

### Schema

```sql
-- Orders table (from Scenario 2) — conflict source
CREATE TABLE orders (
    id          serial PRIMARY KEY,
    customer_id integer NOT NULL,
    amount      numeric(12,2) NOT NULL,
    status      text NOT NULL DEFAULT 'pending',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
-- 500K rows, 3 secondary indexes

-- Probe table — completely separate, measures commit latency
CREATE TABLE probe_s7 (
    id  serial PRIMARY KEY,
    val integer NOT NULL DEFAULT 0,
    ts  timestamptz NOT NULL DEFAULT now()
);
-- 10K rows
```

### Step-by-Step Execution

1. **Churn phase** (30s, `remote_write`): 4 clients DELETE old + INSERT new
   orders, creating ~100K dead tuples
2. **Blocker starts**: standby analytics query opens `REPEATABLE READ` snapshot
   on `orders`, holds it for 70s via `pg_sleep`
3. **VACUUM orders** (`synchronous_commit = local`): prune WAL conflicts with
   the standby's snapshot → replay blocks
4. **Probe pgbench starts** (8 clients, 60s): UPDATE probe_s7 (different table!)
5. Under `remote_apply`: probe TPS drops to 0 for the duration of the blocker
6. Under `remote_write`: probe runs at full speed (~7000 TPS), unaffected

### What to Expect

| Mode | Behavior |
|------|----------|
| `remote_write` | Full ~7000 TPS on probe_s7. Replay lag grows silently. |
| `remote_apply` | **0 TPS for 80+ seconds**. Every commit to probe_s7 waits for replay that's blocked by the orders conflict. |

### Docker-Validated Results (constrained standby)

```
                remote_write    remote_apply    ratio
avg latency     1.2 ms          11,372 ms       9,871x
TPS             6920            0.7             9,871x
```

### Real Hardware Results (identical VMs: 4 CPU, 7.6 GB RAM, PG 17)

```
                remote_write    remote_apply    ratio
avg latency     1.5 ms          3,249 ms        2,200x
TPS             5409            2.5             2,200x
```

Same total freeze under `remote_apply` — 80+ seconds of 0 TPS on `probe_s7`
while the replay conflict on `orders` blocks everything.  The mechanism is
hardware-independent.

The per-5s progress lines:
```
# remote_write: rock-solid 5000+ TPS on probe_s7
progress: ... 6433.9 tps, lat 1.237 ms ...
progress: ... 6811.2 tps, lat 1.171 ms ...
progress: ... 7015.1 tps, lat 1.137 ms ...
progress: ... 7164.4 tps, lat 1.113 ms ...

# remote_apply: total write freeze across ALL tables
progress: ...   10.6 tps ...   ← a few txns before conflict WAL arrived
progress: ...    0.0 tps ...
progress: ...    0.0 tps ...
progress: ...    0.0 tps ...   ← frozen for 80+ seconds
progress: ...    0.0 tps ...   ← writes to probe_s7 blocked by
progress: ...    0.0 tps ...      conflict on orders table!
```

### How This Differs from Scenario 2

| Aspect | Scenario 2 | Scenario 7 |
|--------|-----------|-----------|
| Probe target | Same table (`orders`) | Different table (`probe_s7`) |
| What it shows | Single-table write freeze | **Cross-table** write freeze |
| Key insight | Replay conflict blocks replay | One conflict blocks ALL replay |

### Real-World Relevance

This is the "reporting query on the read replica silently kills production
writes to unrelated tables" scenario.  In practice:
- An analyst runs a long `SELECT` on the `orders` table via the read replica
- Meanwhile, VACUUM runs on the primary (normal autovacuum activity)
- Under `remote_apply`, writes to `users`, `products`, `payments` — every
  table — freeze completely until the analyst's query finishes
- The DBA sees "replication lag" but doesn't realize it's caused by a SELECT
  on a completely different table


## Scenario 8: Table Rewrite (VACUUM FULL + CLUSTER + REINDEX)

**Goal**: Show that heavy table maintenance operations (VACUUM FULL, CLUSTER,
REINDEX) generate massive WAL bursts that overwhelm the standby's replay,
creating extended stalls under `remote_apply`.

### Why This Works

VACUUM FULL rewrites the entire table into a new physical file, generating WAL
for every page of the new table.  CLUSTER does the same but reorders rows by
an index.  REINDEX rebuilds all indexes.  For a 1.5M-row table with 3 indexes:

- VACUUM FULL: ~250 MB of WAL (new heap pages)
- CLUSTER: ~250 MB of WAL (reordered heap pages)
- REINDEX: ~100 MB of WAL (rebuilt index pages)
- Total: ~600 MB of WAL from three operations

The standby must replay all of this serially.  Each operation also acquires
`AccessExclusiveLock`, generating `XLOG_STANDBY_LOCK` WAL records.  If a
standby query holds a conflicting lock on the same table (even a simple
`AccessShareLock` from SELECT), replay blocks until that query finishes —
the same global replay blocking as Scenarios 2 and 7, but triggered by a
**lock conflict** rather than a snapshot/prune conflict.

### Schema

```sql
CREATE TABLE bloated (
    id         integer      PRIMARY KEY,
    status     text         NOT NULL,
    data       text         NOT NULL,   -- ~320 bytes
    extra      text         NOT NULL,   -- ~160 bytes
    updated_at timestamptz  NOT NULL DEFAULT now()
);
-- 3M rows loaded, 50% deleted → 1.5M live rows, ~1.5 GB with bloat

CREATE INDEX bloated_status       ON bloated(status);
CREATE INDEX bloated_updated      ON bloated(updated_at);
CREATE INDEX bloated_data_prefix  ON bloated(left(data, 32));

CREATE TABLE probe_s8 (
    id  serial PRIMARY KEY,
    val integer NOT NULL DEFAULT 0,
    ts  timestamptz NOT NULL DEFAULT now()
);
-- 10K rows — measures commit latency
```

### The Lock Conflict Mechanism

This uses a different conflict type than Scenario 7:

1. A standby query opens a transaction and runs `SELECT count(*) FROM bloated`
   — this acquires `AccessShareLock` on the standby
2. VACUUM FULL on the primary acquires `AccessExclusiveLock` on `bloated`
3. The lock acquisition generates an `XLOG_STANDBY_LOCK` WAL record
4. On the standby, `ResolveRecoveryConflictWithLock()` finds the conflicting
   `AccessShareLock` and pauses replay (with `max_standby_streaming_delay = -1`)
5. ALL replay blocks → `remote_apply` commits to `probe_s8` freeze

| Conflict Type | Scenario 2 & 7 | Scenario 8 |
|---------------|----------------|-----------|
| WAL record | `XLOG_HEAP2_PRUNE` | `XLOG_STANDBY_LOCK` |
| Conflict function | `ResolveRecoveryConflictWithSnapshot()` | `ResolveRecoveryConflictWithLock()` |
| Trigger | VACUUM removing dead tuples | DDL/maintenance acquiring exclusive lock |
| Standby condition | Query's snapshot predates deleted rows | Query holds conflicting lock |

### Step-by-Step Execution

1. **Standby blocker starts**: `SELECT count(*) FROM bloated; pg_sleep(60)` —
   holds `AccessShareLock` for 60s
2. **Probe pgbench starts** (8 clients, 45s, UPDATE probe_s8)
3. **2s baseline** — both modes show ~3000+ TPS
4. **VACUUM FULL bloated** (`synchronous_commit = local`): generates lock WAL
   + rewrite WAL → standby replay blocks
5. **CLUSTER bloated** (`synchronous_commit = local`): more rewrite WAL
6. **REINDEX TABLE bloated** (`synchronous_commit = local`): index rebuild WAL

### What to Expect

| Mode | Behavior |
|------|----------|
| `remote_write` | TPS dips during rewrite operations (primary I/O contention from table rewrite), recovers after. |
| `remote_apply` | 0 TPS freeze from the moment the lock WAL arrives until the standby blocker finishes (~55s). |

### Docker-Validated Results (WAL-volume only, without lock conflict)

```
                remote_write    remote_apply    ratio
avg latency     6.1 ms          7.2 ms          1.2x
TPS             1300            1107            1.2x
```

### Real Hardware Results (with lock conflict, identical VMs: 4 CPU, 7.6 GB RAM, PG 17)

```
                remote_write    remote_apply    ratio
avg latency     2.0 ms          7,187 ms        3,569x
TPS             3969            1.1             3,569x
```

On real hardware with the lock conflict mechanism, the ratio is **dramatic**.
`remote_write` runs at full speed (~4000 TPS) because the standby's lock
conflict doesn't affect WAL writing.  `remote_apply` freezes completely (0 TPS
for 40+ seconds) because replay blocks on the `AccessExclusiveLock` conflict.
This confirms that the Docker result (1.2x) was caused by shared I/O
contention, not a fundamental limitation of the scenario.

**Docker note**: The 1.2x Docker average understates the real impact.  The
per-5s data shows the difference even in Docker:

```
# remote_write: degraded but nonzero during rewrite
progress: ... 2936.8 tps ...   ← baseline
progress: ...    1.6 tps ...   ← VACUUM FULL (primary I/O saturated)
progress: ...    1.6 tps ...
progress: ...  514.0 tps ...   ← recovering
progress: ... 5380.2 tps ...   ← back to full speed

# remote_apply: longer and deeper freeze
progress: ... 2987.2 tps ...   ← baseline
progress: ...    1.6 tps ...   ← VACUUM FULL start
progress: ...    0.0 tps ...   ← fully frozen (replay lagging)
progress: ...    0.0 tps ...
progress: ...    0.0 tps ...   ← still frozen (25s of zero TPS)
progress: ...    0.0 tps ...
progress: ... 1099.4 tps ...   ← replay catching up
progress: ... 5873.0 tps ...   ← recovered
```

Under `remote_apply`, the freeze lasts ~25s (5 intervals of 0 TPS) vs.
~15s under `remote_write`.  The average is compressed because the 45s window
includes the recovery period.  With the lock conflict mechanism (standby
blocker holding AccessShareLock), the freeze extends to the full duration of
the blocker query, producing dramatically higher ratios.

### Why Docker Shows Only 1.2x (I/O Limitation)

VACUUM FULL rewrites the entire table, saturating the primary's disk I/O.  In
Docker, both containers share the same underlying storage.  This means
`remote_write` TPS is ALSO crushed (not just `remote_apply`), compressing the
ratio.  On real hardware with separate storage (as the 3,569x result above
confirms), the primary handles VACUUM FULL with minimal impact on other queries,
and the lock conflict produces a complete `remote_apply` freeze.

### Real-World Relevance

This is the "DBA runs VACUUM FULL during business hours" scenario:
- A table has become bloated (common after bulk deletes or heavy UPDATE churn)
- The DBA runs `VACUUM FULL` to reclaim space
- Reporting queries are running on the standby (normal read-replica usage)
- VACUUM FULL's `AccessExclusiveLock` conflicts with the standby queries
- Under `remote_apply`: all writes to all tables freeze until either the
  standby queries finish or get canceled

Common triggers:
- Manual VACUUM FULL for bloat remediation
- CLUSTER for query performance improvement
- REINDEX after index bloat
- `ALTER TABLE ... ALTER COLUMN TYPE` (rewrites the table)
- `pg_repack` or similar tools that acquire exclusive locks


## Running Scenarios 4-8

```bash
# Run all scenarios 4-8
bash validate_new.sh

# Run specific scenarios
bash validate_new.sh 4 7      # just schema migration and reporting conflict
bash validate_new.sh 8        # just table rewrite
```

The script handles:
- Setting `synchronous_commit` for each mode
- Data setup with `synchronous_commit = local` (to avoid blocking on constrained standby)
- Waiting for replay catchup between runs
- Per-5s progress reporting (`pgbench -P 5 --progress-timestamp`)
- Result comparison with latency ratios


## Monitoring

### Key Query (run on primary)

```sql
SELECT
    now() AS ts,
    application_name,
    sync_state,
    sent_lsn - replay_lsn AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag,
    replay_lag - write_lag AS apply_delta
FROM pg_stat_replication;
```

**`apply_delta`** (`replay_lag - write_lag`) is the exact extra cost that
`remote_apply` adds over `remote_write`.  This is the time between "WAL
written on standby" and "WAL replayed on standby".

### Continuous Monitoring

```bash
watch -n1 "psql -h primary -d bench -c \"
  SELECT now(),
         pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
         write_lag, replay_lag,
         replay_lag - write_lag AS apply_delta
  FROM pg_stat_replication;\""
```

### Standby Conflict Check

```sql
-- On the standby: see if replay is waiting on a query
SELECT * FROM pg_stat_activity
WHERE wait_event_type = 'BufferPin'
   OR query LIKE '%pg_sleep%';
```


## Reproducing on Real Hardware

### Minimum Setup

Two PostgreSQL 16+ servers with streaming replication.  One primary, one
synchronous standby.

### Primary postgresql.conf

```ini
wal_level = replica
max_wal_senders = 10
synchronous_standby_names = '*'     # or a specific app name
synchronous_commit = remote_write   # switch during test
wal_keep_size = 2GB
shared_buffers = 256MB              # or more; primary should be well-resourced
max_wal_size = 4GB
checkpoint_timeout = 15min
```

### Standby postgresql.conf

```ini
hot_standby = on
max_standby_streaming_delay = -1    # for scenario 2
hot_standby_feedback = off          # for scenario 2
recovery_prefetch = off             # optional: makes saturation easier to trigger
shared_buffers = 128MB              # smaller than primary to stress replay cache
```

### Cross-Datacenter Setup

For cross-datacenter benchmarks (e.g., Nuremberg ↔ Helsinki, ~24ms RTT):

1. **`synchronous_commit = local` for all setup operations** is critical — loading
   2M rows with sync commit across 24ms RTT would take forever
2. **Standby `pg_hba.conf`** must allow SQL connections from the primary IP for
   standby blocker queries (S2, S7, S8):
   ```
   host    bench    postgres    <primary_ip>/32    trust
   ```
3. **`max_wal_size = 4GB`** and **`checkpoint_timeout = 15min`** on primary to
   avoid checkpoints during scenarios
4. Copy scenario files to `/tmp/syncrep` (not `/root/` — postgres user needs read access)
5. Run: `bash /tmp/syncrep/run_on_vms.sh`

The script automatically switches between `remote_write` and `remote_apply`
for each scenario and reports both ratio and **added latency** (the pure replay
overhead).

### On Real Hardware, You Don't Need Docker Constraints If:

- **The standby has less RAM**: A standby with 4 GB RAM and a 10+ GB working
  set will naturally have cache misses.
- **The standby has slower disks**: Spinning disks or SATA SSDs vs. the
  primary's NVMe will bottleneck replay I/O.
- **Network latency**: Cross-datacenter (~24ms RTT in our Nuremberg↔Helsinki
  test) adds to both modes, but replay time is additive —
  `remote_apply` latency = network RTT + replay time.  Use "added latency"
  (apply − write) to isolate the pure replay cost.
- **The standby serves read queries**: CPU and I/O consumed by queries
  compete with the startup process.

### Procedure

```bash
# 1. Load data (run on primary)
psql -f scenario1_saturate_indexes/setup.sql  bench
# Wait for standby to catch up
psql -c "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn) FROM pg_stat_replication;"

# 2. Test remote_write
psql -c "ALTER SYSTEM SET synchronous_commit = 'remote_write';"
psql -c "SELECT pg_reload_conf();"
psql -c "CHECKPOINT;"
sleep 2
pgbench -f scenario1_saturate_indexes/workload.sql \
    -c 32 -j 8 -T 60 -P 5 --no-vacuum bench \
    2>&1 | tee results/s1_remote_write.log

# 3. Wait for catchup
while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
    FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done

# 4. Test remote_apply
psql -c "ALTER SYSTEM SET synchronous_commit = 'remote_apply';"
psql -c "SELECT pg_reload_conf();"
psql -c "CHECKPOINT;"
sleep 2
pgbench -f scenario1_saturate_indexes/workload.sql \
    -c 32 -j 8 -T 60 -P 5 --no-vacuum bench \
    2>&1 | tee results/s1_remote_apply.log

# 5. Compare
grep 'latency average' results/s1_remote_write.log results/s1_remote_apply.log
grep '^tps' results/s1_remote_write.log results/s1_remote_apply.log
```

### Scenario 2 on Real Hardware

```bash
# 1. Load data
psql -f scenario2_blocked_conflict/setup.sql bench

# 2. Set mode
psql -c "ALTER SYSTEM SET synchronous_commit = 'remote_apply';"
psql -c "SELECT pg_reload_conf();"

# 3. Start blocker on STANDBY (in another terminal)
psql -h standby -d bench <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM orders WHERE status = 'delivered';
SELECT pg_sleep(90);
COMMIT;
SQL

# 4. Create conflict on PRIMARY (wait 5s for blocker's snapshot first)
sleep 5
psql -d bench \
  -c "SET synchronous_commit TO local" \
  -c "DELETE FROM orders WHERE id IN (
        SELECT id FROM orders
        WHERE status IN ('delivered','cancelled')
        ORDER BY id LIMIT 50000)"
psql -d bench \
  -c "SET synchronous_commit TO local" \
  -c "VACUUM orders"

# 5. Verify replay is blocked
psql -c "SELECT replay_lag, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
         FROM pg_stat_replication;"
# lag_bytes should be > 0 and growing

# 6. Run benchmark — expect 0 TPS
pgbench -f scenario2_blocked_conflict/workload_steady.sql \
    -c 8 -j 4 -T 30 -P 5 --no-vacuum bench
```

### Scenario 3 on Real Hardware (GIN + TOAST)

```bash
# 1. Load data on PRIMARY
psql -d bench -f scenario3_gin_toast/setup.sql

# 2. Wait for standby to catch up
while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
    FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done

# --- Helper: run the test for a given mode ---
run_s3() {
    local MODE=$1
    psql -c "ALTER SYSTEM SET synchronous_commit = '$MODE';"
    psql -c "SELECT pg_reload_conf();"
    psql -c "CHECKPOINT;"
    sleep 2

    # NOTE: pgbench weight syntax is -f file@weight (PG 14+).
    # Older docs/examples may show -f file -w N, which is NOT valid.
    pgbench --no-vacuum bench \
        -f scenario3_gin_toast/workload_insert.sql@7 \
        -f scenario3_gin_toast/workload_update.sql@3 \
        -c 12 -j 6 -T 60 -P 5 --progress-timestamp \
        2>&1 | tee results/s3_${MODE}.log

    # Flush GIN pending lists
    psql -d bench -c "SET synchronous_commit TO local; VACUUM tickets;"

    # Wait for catchup before next mode
    while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
        FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done
}

# 3. Run both modes
run_s3 remote_write
run_s3 remote_apply

# 4. Compare
grep 'latency average' results/s3_remote_write.log results/s3_remote_apply.log
grep '^tps' results/s3_remote_write.log results/s3_remote_apply.log
```

> **pgbench weight syntax**: PostgreSQL 14+ uses `-f script.sql@N` to assign
> relative weights to scripts.  The `-w` flag seen in some older examples is
> **not valid** and will produce `invalid option -- 'w'`.

### Scenario 4 on Real Hardware (Schema Migration)

```bash
# 1. Load data on PRIMARY
psql -d bench -f scenario4_create_index/setup.sql

# 2. Wait for standby to catch up
while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
    FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done

# --- Helper: run the test for a given mode ---
run_s4() {
    local MODE=$1
    psql -c "ALTER SYSTEM SET synchronous_commit = '$MODE';"
    psql -c "SELECT pg_reload_conf();"

    # Drop indexes from previous run
    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "DROP INDEX IF EXISTS events_ts_user" \
      -c "DROP INDEX IF EXISTS events_svc_dur"
    sleep 3

    psql -c "CHECKPOINT;"
    sleep 2

    # Start probe in background (30s, measures commit latency on probe_s4)
    pgbench -f scenario4_create_index/workload_probe.sql \
        -c 8 -j 4 -T 30 -P 5 --progress-timestamp --no-vacuum bench \
        2>&1 > results/s4_${MODE}.log &
    PROBE_PID=$!

    sleep 5   # baseline

    # Run migration with local commit (so it doesn't block on remote_apply)
    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "SET maintenance_work_mem = '256MB'" \
      -c "UPDATE events SET payload = upper(payload)"
    echo "UPDATE done"

    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "CREATE INDEX events_ts_user ON events(ts, user_id)"
    echo "Index 1 done"

    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "CREATE INDEX events_svc_dur ON events(service, duration_ms)"
    echo "Index 2 done"

    wait $PROBE_PID

    # Reset for next run
    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "DROP INDEX IF EXISTS events_ts_user" \
      -c "DROP INDEX IF EXISTS events_svc_dur" \
      -c "UPDATE events SET payload = lower(payload)"

    # Wait for standby to catch up
    while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
        FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done
}

# 3. Test both modes
run_s4 remote_write
run_s4 remote_apply

# 4. Compare
grep 'latency average' results/s4_remote_write.log results/s4_remote_apply.log
grep '^tps' results/s4_remote_write.log results/s4_remote_apply.log
```

### Scenario 5 on Real Hardware (Bulk INSERT / ETL)

```bash
# 1. Load schema on PRIMARY (creates empty indexed table + probe)
psql -d bench -f scenario5_bulk_load/setup.sql

# 2. Wait for standby to catch up
while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
    FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done

# --- Helper ---
run_s5() {
    local MODE=$1
    psql -c "ALTER SYSTEM SET synchronous_commit = '$MODE';"
    psql -c "SELECT pg_reload_conf();"

    # Clear data from previous run
    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "TRUNCATE logs"
    while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
        FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done
    psql -c "CHECKPOINT;"
    sleep 2

    # Start probe in background (60s)
    pgbench -f scenario5_bulk_load/workload_probe.sql \
        -c 8 -j 4 -T 60 -P 5 --progress-timestamp --no-vacuum bench \
        2>&1 > results/s5_${MODE}.log &
    PROBE_PID=$!

    sleep 2   # baseline

    # Bulk load 2M rows with local commit
    psql -d bench <<'EOSQL'
SET synchronous_commit TO local;
INSERT INTO logs (ts, level, service, message, trace_id)
SELECT
    now() - make_interval(days => (random() * 30)::int),
    (ARRAY['DEBUG','INFO','WARN','ERROR','FATAL'])[1+(random()*4)::int],
    (ARRAY['auth','billing','search','export','notify','gateway','worker','scheduler'])[1+(random()*7)::int],
    'Request processed: ' || md5(random()::text) || ' status=' || (200 + (random()*300)::int) || ' duration=' || (random()*1000)::int || 'ms ' || md5(random()::text),
    md5(random()::text)
FROM generate_series(1, 2000000);
EOSQL
    echo "Bulk load done"

    wait $PROBE_PID
}

# 3. Test both modes
run_s5 remote_write
run_s5 remote_apply

# 4. Compare
grep 'latency average' results/s5_remote_write.log results/s5_remote_apply.log
grep '^tps' results/s5_remote_write.log results/s5_remote_apply.log
```

### Scenario 6 on Real Hardware (FPI Storm)

```bash
# 1. Load data on PRIMARY
psql -d bench -f scenario6_fpi_storm/setup.sql

# 2. Wait for standby to catch up
while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
    FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done

# 3. Set short checkpoint interval
psql -c "ALTER SYSTEM SET checkpoint_timeout = '30s';"
psql -c "SELECT pg_reload_conf();"

# --- Helper ---
run_s6() {
    local MODE=$1
    psql -c "ALTER SYSTEM SET synchronous_commit = '$MODE';"
    psql -c "SELECT pg_reload_conf();"
    psql -c "CHECKPOINT;"
    sleep 2

    # Workload IS the probe (24 clients, random scattered UPDATEs)
    pgbench -f scenario6_fpi_storm/workload.sql \
        -c 24 -j 8 -T 60 -P 5 --progress-timestamp --no-vacuum bench \
        2>&1 | tee results/s6_${MODE}.log
}

# 4. Test both modes
run_s6 remote_write
# Wait for catchup
while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
    FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done
run_s6 remote_apply

# 5. Restore checkpoint_timeout
psql -c "ALTER SYSTEM SET checkpoint_timeout = '15min';"
psql -c "SELECT pg_reload_conf();"

# 6. Compare
grep 'latency average' results/s6_remote_write.log results/s6_remote_apply.log
grep '^tps' results/s6_remote_write.log results/s6_remote_apply.log
```

### Scenario 7 on Real Hardware (Reporting Conflict — Cross-Table)

This is the most impactful scenario.  Requires `max_standby_streaming_delay = -1`
and `hot_standby_feedback = off` on the standby (same as Scenario 2).

```bash
# 1. Load data on PRIMARY (orders table + probe table)
psql -d bench -f scenario2_blocked_conflict/setup.sql
psql -d bench -f scenario7_reporting_conflict/setup_probe.sql

# 2. Wait for standby to catch up
while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
    FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done

# --- Helper ---
run_s7() {
    local MODE=$1

    # Phase 1: churn on orders (creates dead tuples) — always under remote_write
    psql -c "ALTER SYSTEM SET synchronous_commit = 'remote_write';"
    psql -c "SELECT pg_reload_conf();"

    pgbench -f scenario2_blocked_conflict/workload_churn.sql \
        -c 4 -j 4 -T 30 --no-vacuum bench 2>&1 | tail -1
    sleep 5

    # Phase 2: start blocker on STANDBY (in another terminal or backgrounded)
    # This holds a REPEATABLE READ snapshot on orders for 70s
    psql -h standby -d bench \
        -f scenario2_blocked_conflict/standby_blocker.sql &
    BLOCKER_PID=$!
    sleep 3

    # Verify blocker is active
    psql -h standby -d bench -tAc \
        "SELECT count(*) FROM pg_stat_activity
         WHERE query LIKE '%pg_sleep%' AND state='active';"

    # Phase 3: switch to test mode and VACUUM
    psql -c "ALTER SYSTEM SET synchronous_commit = '$MODE';"
    psql -c "SELECT pg_reload_conf();"

    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "VACUUM orders"
    sleep 1

    # Phase 4: run probe on probe_s7 (DIFFERENT table than orders!)
    pgbench -f scenario7_reporting_conflict/workload_probe.sql \
        -c 8 -j 4 -T 60 -P 5 --progress-timestamp --no-vacuum bench \
        2>&1 | tee results/s7_${MODE}.log

    # Cleanup: kill standby sessions, wait for blocker
    psql -h standby -d bench -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE pid != pg_backend_pid() AND backend_type = 'client backend';" \
        2>/dev/null || true
    wait $BLOCKER_PID 2>/dev/null || true
    sleep 5

    # Wait for catchup
    while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
        FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done

    # Re-create dead tuples for next run
    if [ "$MODE" = "remote_write" ]; then
        pgbench -f scenario2_blocked_conflict/workload_churn.sql \
            -c 4 -j 4 -T 20 --no-vacuum bench 2>&1 | tail -1
        while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
            FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done
        psql -c "CHECKPOINT;"
        sleep 2
    fi
}

# 3. Test both modes
run_s7 remote_write
run_s7 remote_apply

# 4. Compare
grep 'latency average' results/s7_remote_write.log results/s7_remote_apply.log
grep '^tps' results/s7_remote_write.log results/s7_remote_apply.log
```

**Expected result**: `remote_write` shows ~5000-7000 TPS on `probe_s7`.
`remote_apply` shows **0 TPS** for 60-80 seconds — writes to `probe_s7`
freeze because replay is blocked by the `orders` conflict.

### Scenario 8 on Real Hardware (Table Rewrite)

```bash
# 1. Load data on PRIMARY (3M rows, delete 50%)
psql -d bench -f scenario8_table_rewrite/setup.sql

# 2. Wait for standby to catch up
while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
    FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done

# --- Helper ---
run_s8() {
    local MODE=$1

    # Start standby blocker (holds AccessShareLock on bloated for 60s)
    psql -h standby -d bench \
        -f scenario8_table_rewrite/standby_blocker.sql &
    BLOCKER_PID=$!
    sleep 3

    # Verify blocker is active
    psql -h standby -d bench -tAc \
        "SELECT count(*) FROM pg_stat_activity
         WHERE query LIKE '%pg_sleep%' AND state='active';"

    # Switch to test mode
    psql -c "ALTER SYSTEM SET synchronous_commit = '$MODE';"
    psql -c "SELECT pg_reload_conf();"
    psql -c "CHECKPOINT;"
    sleep 1

    # Start probe in background (45s)
    pgbench -f scenario8_table_rewrite/workload_probe.sql \
        -c 8 -j 4 -T 45 -P 5 --progress-timestamp --no-vacuum bench \
        2>&1 > results/s8_${MODE}.log &
    PROBE_PID=$!

    sleep 2   # baseline

    # Run rewrite operations with local commit
    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "VACUUM FULL bloated"
    echo "VACUUM FULL done"

    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "CLUSTER bloated USING bloated_pkey"
    echo "CLUSTER done"

    psql -d bench \
      -c "SET synchronous_commit TO local" \
      -c "REINDEX TABLE bloated"
    echo "REINDEX done"

    wait $PROBE_PID

    # Cleanup
    psql -h standby -d bench -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE pid != pg_backend_pid() AND backend_type = 'client backend';" \
        2>/dev/null || true
    wait $BLOCKER_PID 2>/dev/null || true
    sleep 5

    # Wait for catchup
    while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
        FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done
}

# 3. Test remote_write
run_s8 remote_write

# 4. Re-create bloat for next run
psql -d bench <<'EOSQL'
SET synchronous_commit TO local;
INSERT INTO bloated SELECT i, 'pending', repeat(md5(i::text), 10),
    repeat(md5(i::text), 5), now()
FROM generate_series(2, 3000000, 2) i
ON CONFLICT (id) DO NOTHING;
DELETE FROM bloated WHERE id % 2 = 0;
EOSQL
while [ "$(psql -tAc "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn)::bigint
    FROM pg_stat_replication;")" -gt 65536 ]; do sleep 1; done
psql -c "CHECKPOINT;"
sleep 2

# 5. Test remote_apply
run_s8 remote_apply

# 6. Compare
grep 'latency average' results/s8_remote_write.log results/s8_remote_apply.log
grep '^tps' results/s8_remote_write.log results/s8_remote_apply.log
```

**Expected result**: On real hardware with separate storage, `remote_write`
maintains reasonable TPS during the rewrite (primary I/O is local and fast).
`remote_apply` freezes completely because the lock conflict blocks all replay.
The ratio should be much higher than the Docker result (1.2x) where shared
storage compresses the difference.


## Results Summary

### Docker (constrained standby: PG 16, 0.5 CPU, 384 MB RAM, 48 MB shared_buffers)

| # | Scenario | Mechanism | remote_write | remote_apply | Ratio |
|---|----------|-----------|-------------|-------------|-------|
| S7 | Reporting conflict (cross-table) | Replay blocking (snapshot) | 1.2 ms / 6,920 TPS | 11,372 ms / 0.7 TPS | **9,871x** |
| S2 | Standby query conflict | Replay blocking (snapshot) | 0.37 ms / 21,668 TPS | 2,304 ms / 3.5 TPS | **6,200x** |
| S1 | Index-heavy UPDATE saturation | Replay saturation | 9.8 ms / 3,250 TPS | 87.2 ms / 367 TPS | **8.9x** |
| S5 | Bulk INSERT (ETL) | Replay saturation | 6.7 ms / 1,191 TPS | 42.1 ms / 190 TPS | **6.3x** |
| S4 | Schema migration | Replay saturation (WAL burst) | 4.9 ms / 1,642 TPS | 10.7 ms / 749 TPS | **2.2x** |
| S6 | FPI storm | Replay saturation (WAL amplification) | 5.1 ms / 4,684 TPS | 10.9 ms / 2,197 TPS | **2.1x** |
| S3 | GIN + TOAST | Replay saturation (bursty) | 8.0 ms / 1,490 TPS | 14.3 ms / 840 TPS | **1.8x** |
| S8 | Table rewrite (VACUUM FULL) | WAL burst (no lock conflict) | 6.1 ms / 1,300 TPS | 7.2 ms / 1,107 TPS | **1.2x** |

### Real Hardware (identical VMs: PG 17, 4 CPU, 7.6 GB RAM, 128 MB shared_buffers)

| # | Scenario | Mechanism | remote_write | remote_apply | Ratio |
|---|----------|-----------|-------------|-------------|-------|
| S8 | Table rewrite (VACUUM FULL) | WAL burst + lock conflict | 2.0 ms / 3,969 TPS | 7,187 ms / 1.1 TPS | **3,569x** |
| S2 | Standby query conflict | Replay blocking (snapshot) | 0.26 ms / 30,368 TPS | 861 ms / 9.3 TPS | **3,273x** |
| S7 | Reporting conflict (cross-table) | Replay blocking (snapshot) | 1.5 ms / 5,409 TPS | 3,249 ms / 2.5 TPS | **2,200x** |
| S5 | Bulk INSERT (ETL) | Replay saturation | 1.8 ms / 4,359 TPS | 5.3 ms / 1,505 TPS | **2.9x** |
| S4 | Schema migration | Replay saturation (WAL burst) | 1.8 ms / 4,352 TPS | 4.6 ms / 1,751 TPS | **2.5x** |
| S3 | GIN + TOAST | Replay saturation (bursty) | 4.2 ms / 2,825 TPS | 8.8 ms / 1,367 TPS | **2.1x** |
| S6 | FPI storm | Replay saturation (WAL amplification) | 3.4 ms / 7,148 TPS | 4.8 ms / 5,049 TPS | **1.4x** |
| S1 | Index-heavy UPDATE saturation | Replay saturation | 8.3 ms / 3,857 TPS | 9.9 ms / 3,228 TPS | **1.2x** |

### Cross-Datacenter (PG 18, Nuremberg ↔ Helsinki, ~24ms RTT)

| Primary | Replica | Network RTT | PG Version |
|---------|---------|-------------|------------|
| 46.225.179.227 (Nuremberg) | 89.167.39.203 (Helsinki) | ~24 ms | 18.2 |
| 4 CPU, 7.6 GB RAM | 4 CPU, 7.6 GB RAM | | |

**Why "added latency" is the right metric here:**

With ~24ms network RTT, both `remote_write` and `remote_apply` include the
same base cost: query execution time + network round-trip.  The difference
between them — `added_latency = remote_apply − remote_write` — isolates the
pure **replay overhead** on the standby.  This makes it a cleaner measure than
the ratio, which is compressed by the large shared base (the ~24ms RTT).

| # | Scenario | Mechanism | remote_write | remote_apply | Added Latency | Ratio |
|---|----------|-----------|-------------|-------------|---------------|-------|
| S7 | Reporting conflict (cross-table) | Replay blocking (snapshot) | 26.2 ms / 305 TPS | 16,702 ms / 0.5 TPS | **+16,676 ms** | 638x |
| S8 | Table rewrite (VACUUM FULL) | Lock conflict | 159.2 ms / 50 TPS | 12,847 ms / 0.6 TPS | **+12,688 ms** | 80.7x |
| S2 | Standby query conflict | Replay blocking (snapshot) | 3.3 ms / 2,396 TPS | 2,399 ms / 3.3 TPS | **+2,396 ms** | 719x |
| S5 | Bulk INSERT (ETL) | Replay saturation | 30.2 ms / 265 TPS | 82.1 ms / 97 TPS | **+51.9 ms** | 2.7x |
| S4 | Schema migration | Replay saturation (WAL burst) | 41.9 ms / 191 TPS | 51.6 ms / 155 TPS | **+9.7 ms** | 1.2x |
| S6 | FPI storm | Replay saturation (WAL amplification) | 29.1 ms / 825 TPS | 33.9 ms / 707 TPS | **+4.9 ms** | 1.2x |
| S3 | GIN + TOAST | Replay saturation (bursty) | 30.7 ms / 390 TPS | 34.4 ms / 349 TPS | **+3.6 ms** | 1.1x |
| S1 | Index-heavy UPDATE saturation | Replay saturation | 31.6 ms / 1,013 TPS | 31.5 ms / 1,015 TPS | **−0.1 ms** | 1.0x |

### Key Takeaways

- **Replay blocking scenarios (S2, S7, S8)** add **seconds** of latency on any
  hardware. The conflict mechanism completely stops replay — added latency equals
  the full duration of the standby blocker query.
- **S7 is the worst case (+16.7 seconds)**: a single reporting query on a
  _different_ table freezes writes to _all_ tables.  This is the most dangerous
  production scenario — it's invisible until you measure it.
- **S5 bulk load (+52ms)** shows that heavy WAL from ETL/batch jobs adds
  meaningful latency even without conflicts.  The standby's single-threaded
  replay simply cannot keep up with 2M indexed inserts.
- **Saturation scenarios (S1, S3-S6)** add 0-52ms depending on WAL volume.
  On identical hardware with ~24ms RTT, the ratio looks small (1.0-2.7x) because
  the network base dominates — but the **absolute added latency** reveals the
  real cost.
- **S1 shows zero added latency** (−0.1ms): when both VMs are identical and the
  standby can keep up with replay, `remote_apply` costs nothing extra.  This
  confirms that the overhead only appears when the standby is actually behind.
- **Cross-datacenter ratios appear lower** than same-datacenter because ~24ms RTT
  inflates the `remote_write` baseline.  Same-datacenter S7 showed 2,200x;
  cross-datacenter shows 638x — but the added latency is similar (~16.7s vs ~3.2s,
  the difference being the longer blocker query duration).


## File Reference

```
syncrep/
├── README.md                          ← this file
├── validate.sh                        ← automated Docker test runner (S1-S3)
├── validate_new.sh                    ← automated Docker test runner (S4-S8)
├── run_on_vms.sh                      ← runner for real VMs (all 8 scenarios)
├── docker/
│   ├── docker-compose.yml             ← two-node cluster definition
│   ├── primary/init.sh                ← enables sync rep via ALTER SYSTEM
│   └── standby/entrypoint.sh          ← pg_basebackup + constrained startup
├── common/
│   ├── compare_modes.sh               ← helper: run pgbench under both modes
│   └── monitor_lag.sql                ← pg_stat_replication query
├── scenario1_saturate_indexes/
│   ├── setup.sql                      ← 2M rows, 16 indexes, fillfactor=50
│   ├── workload.sql                   ← random UPDATE changing 7 indexed cols
│   └── run.sh                         ← standalone runner (non-Docker)
├── scenario2_blocked_conflict/
│   ├── setup.sql                      ← 500K order rows
│   ├── workload_churn.sql             ← DELETE old + INSERT new orders
│   ├── workload_steady.sql            ← lightweight status UPDATE (the probe)
│   ├── standby_blocker.sql            ← REPEATABLE READ + pg_sleep on standby
│   └── run.sh
├── scenario3_gin_toast/
│   ├── setup.sql                      ← 300K rows, 4 GIN, 10-30KB TOAST bodies
│   ├── workload_insert.sql            ← INSERT with large body + GIN updates
│   ├── workload_update.sql            ← UPDATE body + metadata (TOAST rewrite)
│   └── run.sh
├── scenario4_create_index/
│   ├── setup.sql                      ← 2M rows events table + probe
│   └── workload_probe.sql             ← lightweight UPDATE on probe_s4
├── scenario5_bulk_load/
│   ├── setup.sql                      ← indexed logs table (empty) + probe
│   └── workload_probe.sql             ← lightweight UPDATE on probe_s5
├── scenario6_fpi_storm/
│   ├── setup.sql                      ← 2M rows, fillfactor=50, wide padding
│   └── workload.sql                   ← random scattered UPDATE
├── scenario7_reporting_conflict/
│   ├── setup_probe.sql                ← probe_s7 table (orders from S2 setup)
│   ├── workload_probe.sql             ← lightweight UPDATE on probe_s7
│   ├── setup.sql                      ← (legacy) sales table
│   └── workload_churn.sql             ← (legacy) churn on sales
├── scenario8_table_rewrite/
│   ├── setup.sql                      ← 3M rows, 50% deleted → bloated + probe
│   ├── workload_probe.sql             ← lightweight UPDATE on probe_s8
│   └── standby_blocker.sql            ← AccessShareLock on bloated + pg_sleep
└── results/                           ← pgbench output logs (s[1-8]_*.log)
```
