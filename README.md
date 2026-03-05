# remote_write vs remote_apply — Latency Benchmark Suite

Demonstrates **when and why** `synchronous_commit = remote_apply` adds latency
compared to `remote_write` on a live PostgreSQL synchronous-replication cluster.

Twelve default scenarios cover every distinct mechanism: snapshot conflicts, lock
conflicts, buffer-pin stalls, WAL replay throughput, per-record fsync overhead,
and replay saturation at high concurrency. Each scenario is self-contained.

---

## Background

With synchronous replication, the primary waits for the standby before
returning success to the client. The exact wait point depends on
`synchronous_commit`:

```
  CLIENT commits
      │
  Primary writes WAL to disk, sends to standby
      │
      ├─ remote_write ──►  standby writes WAL to OS page cache → ACK
      │
      ├─ remote_flush ──►  standby flushes WAL to disk → ACK
      │
      └─ remote_apply ──►  standby startup process replays WAL → ACK
```

`remote_apply` provides the strongest durability and read-your-writes
guarantee: once committed, the change is immediately visible on the standby.
The cost is that the primary now waits for **replay** — a single-threaded
process that can be slowed or stalled by anything happening on the standby.

### When does replay stall?

Two distinct mechanisms cause replay to block:

**1. Hot standby conflict resolution**
When replaying WAL that conflicts with an active query on the standby,
`startup` calls `ResolveRecoveryConflict*()`. With
`max_standby_streaming_delay = -1` (the benchmark default), it waits
indefinitely rather than cancelling the standby query. The primary's commit
hangs for the entire duration.

Conflict types:
- **Snapshot conflict** — a standby query holds an old snapshot; WAL tries
  to prune rows that snapshot still needs (`ResolveRecoveryConflictWithSnapshot`)
- **Lock conflict** — a standby query holds `AccessShareLock`; WAL tries
  to replay an `AccessExclusiveLock` operation (`ResolveRecoveryConflictWithLock`)
- **Buffer pin conflict** — a standby query has a page pinned; WAL replay
  needs a cleanup lock on that page (`ResolveRecoveryConflictWithBufferPin`)

**2. Pure replay overhead (no conflict)**
Even without blocking queries on the standby, replay itself takes time:
- Large transactions produce large WAL that takes time to apply
- Schema-altering operations trigger filesystem calls per object during replay
- `VACUUM FULL` with `wal_level = logical` calls `pg_fsync()` for every
  rewrite mapping record written during replay

Under `remote_write`, none of this matters — the primary only waits for the
WAL bytes to reach the standby's memory. Under `remote_apply`, every extra
millisecond of replay adds directly to commit latency.

### Pipelining and network latency

Both modes use the same WAL sender, which streams WAL continuously without
waiting for acknowledgment between records. This **pipelining** means
throughput is not limited to one commit per network round trip — hundreds of
commits can be in-flight simultaneously.

However, every individual commit still waits in `SyncRepWaitForLSN()` until
the standby acknowledges its LSN. With 10 ms one-way network latency (20 ms
RTT), every commit pays at least ~20 ms regardless of mode.

The critical difference is **how the standby acknowledges**:

- **`remote_write`**: the standby writes WAL to OS page cache — effectively
  instant for all concurrent commits. One feedback message comes back and
  releases all waiting backends at once. 100 concurrent commits each pay
  ~20 ms, and all finish at roughly the same time.

- **`remote_apply`**: the standby startup process **replays** WAL
  sequentially (single-threaded). `replay_lsn` advances one commit at a
  time. Feedback messages come back as replay progresses, releasing backends
  in batches. The first commits in the queue pay ~20 ms (same as
  `remote_write`), but later commits must wait for all preceding WAL to be
  replayed first.

Under **light load** (small transactions, replay keeps up), the total replay
time for all concurrent commits is sub-millisecond — effectively identical
to `remote_write`.

Under **heavy load** (many writers, large transactions), replay cannot keep
up, the queue grows, and later commits pay RTT + full queue drain time. This
is the fundamental asymmetry: **`remote_write` acknowledgments are parallel
(OS cache write is instant), `remote_apply` acknowledgments are serialized
through single-threaded replay.** This is exactly what the benchmark
scenarios demonstrate.

### Latency sources at a glance

| Scenario | Mechanism | Magnitude | `hsf=on` fixes it? |
|----------|-----------|-----------|---------------------|
| S2 Snapshot conflict | Replay stall (snapshot) | **BLOCKED** (0 TPS for 60-80s) | Yes |
| S7 Cross-table blast | Replay stall (snapshot) | **BLOCKED** (0 TPS for 60-80s) | Yes |
| S8 VACUUM FULL lock | Replay stall (lock) | **BLOCKED** (0 TPS for 60-80s) | **No** |
| S10 Large UPDATE | WAL replay throughput | ~350 ms | **No** |
| S12 Logical rewrite | pg_fsync per rewrite record | +336 ms (300K rows); scales with rows × fsync latency | **No** |
| S11 DROP partitions | unlink() per file on replay | scales with N parts | **No** |
| S14 Replay saturation | WAL gen > single-thread replay | grows with concurrency | **No** |
| S4 Schema migration | WAL backlog from parallel DDL | +2–5 s (wall clock) | **No** |
| S1 Index-heavy scattered | ~800 page mods per commit | +10–15 ms | — |
| S3 GIN/TOAST batch | CPU-bound GIN replay | +10–15 ms | — |

**Blocking scenarios** (S2, S7, S8): `remote_apply` commits freeze completely
(0 TPS) for the entire duration of the standby conflict. The benchmark detects
this via pgbench progress lines and reports `BLOCKED — 0 TPS for Xs` instead
of misleading average latency.

**Key insight**: `hot_standby_feedback = on` prevents only snapshot conflicts
(S2, S7). Lock conflicts (S8) and all
non-conflict replay overhead (S4, S10–S12, S14) are unaffected — because
they have nothing to do with row visibility. See [Effect of
`hot_standby_feedback`](#effect-of-hot_standby_feedback) for the full
tradeoff including the bloat cost.

### Excluded scenarios

Three scenarios are excluded from defaults because their effects are too
marginal to demonstrate reliably:

- **S5** (Bulk INSERT): single large INSERT; added latency depends on
  standby I/O throughput but is typically < 5 ms on fast storage.
- **S6** (FPI storm): Full Page Image amplification after checkpoints.
  The effect scales with `shared_buffers` size and is only dramatic at
  production scale (64+ GB `shared_buffers`). In symmetric benchmark configs,
  FPI replay is fast (~300–500 MB/s on NVMe) and the effect is marginal.
- **S13** (Hash VACUUM): dual conflict (snapshot + buffer pin) exists in
  code but the overlap window is too narrow for reliable demonstration.

These scenarios remain in the repo and can be run explicitly:
`bash run.sh 5 6 13`.

---

## Prerequisites

**Test environment storage**: The results in this document were collected on
servers using **Pure Storage** network-attached volumes — not local NVMe.
Scenarios sensitive to fsync latency (S11, S12) may show different results on
local disks vs network-attached storage. See individual scenario sections for
details.

- Two PostgreSQL servers (primary + synchronous standby) managed by Patroni
- `synchronous_mode: true` in Patroni config (or `synchronous_standby_names`
  set manually in `postgresql.conf`)
- `pgbench` on the machine running the benchmarks — same major version as the
  server, or within one major version. Check with `pgbench --version`.
- Network access from the benchmark machine to both servers on port 5432
- The PostgreSQL user set in `syncrep.conf` must be a superuser (needs
  `ALTER SYSTEM`, `pg_reload_conf()`, `pg_stat_replication`)

### Server settings to verify

**Both nodes — `statement_timeout`**

All scenarios use long-running standby queries (up to 90 s) to hold conflicts.
If `statement_timeout` is set to a low value (common in production), those
queries will be cancelled before the conflict materialises and the scenario
will show no latency difference. Verify:

```sql
SHOW statement_timeout;   -- must be 0 (unlimited) or ≥ 120s
```

If needed, the scripts override it for standby blocker sessions automatically.
But if the primary also has a low `statement_timeout`, set it to `0` before
running.

**Primary — `wal_level` (Scenario 12 only)**

S12 requires `wal_level = logical`. If your cluster already uses logical
replication this is already set. Otherwise S12 is automatically skipped with a
warning — no other scenario requires it.

```sql
SHOW wal_level;   -- 'logical' for S12, 'replica' is fine for all others
```

### Standby configuration (handled automatically)

`setup_patroni_env.sh` sets these on the standby — you do not need to set them
manually:

```sql
-- Wait forever on conflicts instead of cancelling standby queries.
-- Required for conflict scenarios (S2, S7, S8) to be meaningful.
ALTER SYSTEM SET max_standby_streaming_delay = '-1';

-- Prevent the standby from suppressing VACUUM on the primary.
-- Required for snapshot-conflict scenarios (S2, S7) to generate
-- the conflict WAL that causes replay stalls.
ALTER SYSTEM SET hot_standby_feedback = off;
```

See [Effect of `hot_standby_feedback`](#effect-of-hot_standby_feedback) for
the full tradeoff.

---

## Quick Start

```bash
# 1. Clone and configure
git clone <repo>
cd syncrep
cp syncrep.conf.example syncrep.conf
$EDITOR syncrep.conf          # fill in IPs, credentials — everything else is automatic

# 2. Verify cluster, create bench DB, configure standby settings
bash setup_patroni_env.sh

# 3. Run all default scenarios (12 scenarios, ~90 min)
bash run.sh

# 4. Run a subset (e.g. scenarios 2, 7, 8 — the dramatic conflict cases)
bash run.sh 2 7 8

# 5. Print summary report from saved results
bash report.sh
```

Scripts auto-source `syncrep.conf` from their own directory — no need to source
it manually. If you want to override a variable for a single run without editing
the file, export it before calling the script:

```bash
RESULTS_DIR=/my/results bash run.sh
```

### syncrep.conf fields

| Variable | Description |
|----------|-------------|
| `PRIMARY_HOST` | IP or hostname of the Patroni leader (primary) |
| `PRIMARY_PORT` | PostgreSQL port on primary (usually 5432) |
| `STANDBY_HOST` | IP or hostname of the sync standby |
| `STANDBY_PORT` | PostgreSQL port on standby |
| `PGUSER` | Superuser name (needs `pg_stat_replication`, `ALTER SYSTEM`) |
| `PGPASSWORD` | Password for that user |
| `PGDATABASE` | Database for benchmarks — will be created if absent (`bench`) |
| `SQL_DIR` | Absolute path to this repo (needed by `pgbench -f`) |
| `RESULTS_DIR` | Where per-scenario result files are written |

---

## Scenarios

Each scenario runs the workload twice — once under `synchronous_commit =
remote_write`, once under `remote_apply` — and prints the difference.
All tables are created automatically; no manual setup is needed.

**Default scenarios** (run by `bash run.sh` with no arguments):
S1, S2, S3, S4, S7, S8, S10, S11, S12, S14

**Run all scenarios** (~90 min total):
```bash
bash run.sh
```

**Run one scenario**:
```bash
bash run.sh 7        # just S7
bash run.sh 2 7 8    # S2, S7, and S8 — the three blocking conflict cases
```

**Watch results build up** in a second terminal:
```bash
bash report.sh       # re-run any time; reads whatever result files exist
```

---

### S1 — Index-heavy scattered UPDATE (100 rows × 15 indexes)

```bash
bash run.sh 1   # ~3 min
```

**Setup**: 2 M-row table with 15 B-tree indexes (8 per-column, 4 composite,
3 functional), fillfactor 50.

**What it does**: Each pgbench transaction updates 100 rows **scattered** across
the full table (spaced ~20,000 apart). Unlike contiguous `BETWEEN` ranges
where rows share heap pages, scattered rows each land on a different heap page
and different index leaf pages. Runs 45 s at 32 clients.

**Why latency increases**: 100 scattered rows × 15 indexes ≈ 1,600 distinct
page modifications per commit. Each page modification during replay requires a
buffer lookup and apply. Contiguous rows share pages (fast); scattered rows
force random buffer access (slow). The replay overhead per commit is
proportional to the number of *distinct pages* modified, not just row count.

**What to look for**:
```
avg latency (ms)       remote_write   remote_apply
                             2.1            41.5
Added latency: +39.4 ms
```
The per-5 s progress lines should stay stable — no spikes.

**Typical result**: +20–40 ms

---

### S2 — Snapshot conflict (blocked replay)

```bash
bash run.sh 2   # ~6 min
```

**Setup**: `orders` table (500 K rows) with heavy churn. A second table
(`probe_s2`) is used for the latency probe pgbench.

**What it does**:
1. Opens a `REPEATABLE READ` query on the standby: `SELECT count(*), pg_sleep(90)` — holds an old snapshot for 90 s.
2. Runs `UPDATE orders + VACUUM orders` on the primary in a loop — VACUUM generates `XLOG_HEAP2_PRUNE_FREEZE` WAL that conflicts with the standby snapshot.
3. Simultaneously probes primary commit latency with pgbench (30 s).

**Mechanism**:
- VACUUM on the primary tries to prune dead rows the standby snapshot still needs.
- Replay calls `ResolveRecoveryConflictWithSnapshot()` and waits.
- With `max_standby_streaming_delay = -1`, it waits indefinitely — every primary commit blocks until the standby query finishes.
- `remote_write` is completely unaffected: it doesn't wait for replay.

**What to look for**:
```
BLOCKED — remote_apply: 0 TPS for 65s out of 70s (340x TPS drop)
```
Watch the per-5 s progress lines during `remote_apply` — TPS drops to 0.0
immediately when the conflict starts, then recovers when the standby query
finishes. The `replay_lag` column in `pg_stat_replication` shows the growing
WAL backlog.

**Typical result**: BLOCKED — all commits frozen for 60–80 s

---

### S3 — GIN + TOAST batch (30 rows scattered)

```bash
bash run.sh 3   # ~4 min
```

**Setup**: `tickets` table with four GIN indexes (text search, trigrams, tags
array, metadata jsonb). Rows contain 10–30 KB of text stored via TOAST.
`gin_pending_list_limit = 64 KB` for frequent flushes.

**What it does**: 70/30 mix of INSERT (30 rows) and UPDATE (30 scattered rows).
UPDATE rows are spaced 10,000 apart across the 300K-row table, hitting
different heap pages and GIN/btree leaf pages. 24 clients, 45 s per mode.

**Why latency increases**: GIN replay is CPU-bound, not I/O-bound. Each 30-row
batch fills the GIN pending list multiple times, triggering CPU-intensive
posting tree flushes. Scattered UPDATEs multiply distinct page modifications.
TOAST chunks generate many small WAL records per row.

**What to look for**: Per-5 s progress lines that are slightly uneven — bursty
WAL causes small latency spikes when GIN flushes its pending list.

**Typical result**: +10–20 ms

---

### S4 — Schema migration (parallel UPDATE + CREATE INDEX)

```bash
bash run.sh 4   # ~10 min
```

**Setup**: `events` table (2 M rows) with 4 secondary B-tree indexes on
`(user_id, ts)`, `(duration_ms)`, `(service, ts)`, `(user_id, duration_ms)`.
A probe table (`probe_s4`) measures the first synchronous commit after the
migration finishes.

**What it does**: 4 parallel UPDATE sessions each handle 500 K rows (touching
indexed columns `user_id` and `duration_ms`), then 2 indexes are created —
all with `synchronous_commit = local`. After the migration finishes, a single
synchronous `INSERT` into the probe table measures how long the standby takes
to catch up with the WAL backlog.

**Why latency increases**: 4 concurrent UPDATE sessions generate WAL
simultaneously from 4 CPU cores, but replay is single-threaded. Combined WAL
rate from 4 sessions exceeds single-threaded replay throughput → a WAL backlog
builds during the migration. After the migration finishes, the standby has
already received the WAL (write_lsn is current) but has not finished replaying
it (replay_lsn is behind). Under `remote_write` the first commit returns
instantly (~RTT). Under `remote_apply` it must wait for the entire WAL
backlog to be replayed — seconds of stall.

**What to look for**:
```
  remote_write:      3 ms    (standby already received WAL)
  remote_apply:   4200 ms    (waited for WAL backlog replay)
```
The `pg_stat_replication` output shown right before the probe commit reveals
the replay backlog: `replay_lag` will be in seconds while `write_lag` is
milliseconds.

**Typical result**: +2–5 s; scales with migration WAL volume

---

### S7 — Reporting query blocks replay (cross-table blast radius)

```bash
bash run.sh 7   # ~6 min
```

**Setup**: Same `orders` table as S2. A separate probe table (`probe_s7`) is
updated by the latency measurement pgbench.

**What it does**: Same snapshot-conflict mechanism as S2, but the pgbench probe
writes to a *different* table than the one being VACUUMed. Demonstrates that
replay stalls are **global** — not limited to the conflicting table.

**Mechanism**: A snapshot conflict stalls the startup process entirely. While
startup waits, it cannot replay WAL for *any* table. Every primary commit —
regardless of which table it touches — blocks under `remote_apply` until the
standby query finishes.

**What to look for**:
```
BLOCKED — remote_apply: 0 TPS for 80s out of 85s (350x TPS drop)
```
Watch `pg_stat_replication` during the run — `replay_lag` will show hours or
days (the standby has completely stopped replaying), while `write_lag` and
`flush_lag` stay at milliseconds. This gap is the visible signature of a replay
stall.

**Typical result**: BLOCKED — all commits frozen for 60–80 s

---

### S8 — Table rewrite / lock conflict

```bash
bash run.sh 8   # ~8 min (3 M-row table setup takes ~2 min)
```

**Setup**: `bloated` table (3 M rows, heavily dead-tupled). A probe table
(`probe_s8`) takes the latency measurement.

**What it does**:
1. Starts a long-running `SELECT count(*) FROM bloated` on the standby —
   holds `AccessShareLock`.
2. Runs `VACUUM FULL bloated` on the primary — requests `AccessExclusiveLock`.
3. Simultaneously measures primary commit latency on `probe_s8`.

**Mechanism**: `VACUUM FULL` produces lock conflict WAL (not snapshot conflict).
Replay calls `ResolveRecoveryConflictWithLock()`. The standby's `AccessShareLock`
on `bloated` conflicts with the replayed `AccessExclusiveLock` — startup waits
until the SELECT finishes or is cancelled.

**Why `hot_standby_feedback` does not help**: Feedback only prevents snapshot
conflicts (VACUUM skipping rows needed by old snapshots). It has no effect on
lock-type conflicts — `VACUUM FULL` requests `AccessExclusiveLock` regardless.

**What to look for**:
```
BLOCKED — remote_apply: 0 TPS for 60s out of 70s (170x TPS drop)
```
`replay_lag` in `pg_stat_replication` shows hours while the blocker holds.

**Typical result**: BLOCKED — all commits frozen for 60–80 s

---

### S10 — Large synchronous UPDATE

```bash
bash run.sh 10   # ~8 min
```

**Setup**: `big_updates` table (1 M rows, 4 indexes).

**What it does** (two parts):

**Part A — pgbench**: Each pgbench transaction updates 10 000 rows in one
commit (~large WAL per transaction). Measures average per-transaction latency
over 30 s, 8 clients.

**Part B — wall clock**: A single `UPDATE big_updates SET ...` touching all
1 M rows in one transaction. Measures wall-clock time for the full commit to
return.

**Why latency increases (Part A)**: Each large-UPDATE transaction produces
proportionally more WAL. `remote_apply` must wait for all of it to replay.
The gap widens linearly with rows-per-transaction.

**Part B note**: Wall-clock includes both primary execution and standby replay
time. On identical hardware these are similar, so the ratio may be close to 1×.

**What to look for**:
```
  S10 Part A (pgbench):   rw=1581 ms   ra=1916 ms   +334 ms
  S10 Part B (wall clock): rw=18861 ms  ra=17854 ms  ≈ same
```
Part A shows a reliable delta; Part B is noisy because both sides do I/O.

**Typical result**: Part A +300–400 ms; Part B near-zero difference

---

### S11 — DROP TABLE on partitioned table (50 partitions)

```bash
bash run.sh 11   # ~6 min (partition table setup ~60 s on first run)
```

**Setup**: 50-partition hash-partitioned table (`part_test`) with data, indexes,
and TOAST tables — created fresh for each mode pass.

**What it does**: Measures wall-clock time for `DROP TABLE part_test CASCADE`
under each sync mode.

**Why latency increases**: The commit record for `DROP TABLE` lists every
dropped relation. During replay, `xact_redo_commit()` calls
`RelationDropStorage()` — a synchronous `unlink()` syscall — for each file
fork of each relation before it can advance. With 50 partitions × heap + FSM
+ VM + index forks ≈ 500+ sequential file unlinks during a single commit replay.

**What to look for**:
```
  remote_write:  786 ms
  remote_apply:  832 ms    (+46 ms)
```
The difference is pure filesystem overhead on the standby. On NVMe this is
small; on spinning disks or network-attached storage it grows significantly.

**Typical result**: +40–60 ms; scales linearly with partition count

**Scale**: 10,000 partitions → ~100,000 unlinks → 10+ seconds of stall per DROP.

---

### S12 — VACUUM FULL with logical replication slot

```bash
bash run.sh 12   # ~5 min  (requires wal_level = logical — skipped otherwise)
```

**Setup**: `rewrite_test` table (300 K rows), a logical replication slot
(`syncrep_bench_slot`). The slot is dropped automatically at the end.

**What it does**: Bloats `rewrite_test` by updating all rows (doubles dead
tuples), then runs `VACUUM FULL` under each sync mode and measures wall-clock
time.

**Mechanism** (`rewriteheap.c:heap_xlog_logical_rewrite`): When `wal_level =
logical` and a logical slot exists, `VACUUM FULL` writes `XLOG_HEAP2_REWRITE`
records for every row moved (old→new TID mappings). During replay,
`heap_xlog_logical_rewrite()` calls `pg_fsync(fd)` **after every single
record** — not once at the end. For 300 K rows: ~300 individual fsyncs during
replay of one commit.

**Without a logical slot**: no `XLOG_HEAP2_REWRITE` records, no fsyncs —
`VACUUM FULL` completes identically under both modes.

**What to look for**:
```
  remote_write:  2197 ms
  remote_apply:  2533 ms    (+336 ms)
```
Both modes generate the same WAL; the difference is entirely the standby
spending time calling `pg_fsync()` on mapping files.

**Typical result**: +200–400 ms with 300K rows; scales linearly with row count

**fsync latency matters**: The overhead is `N_fsyncs × fsync_latency`.
The benchmark results above were measured on **Pure Storage network-attached
volumes** (not local NVMe). On this storage, each fsync averages ~1 ms —
comparable to local NVMe under normal conditions. However, network-attached
storage fsync latency is inherently less predictable: while the median may be
~1 ms, tail latencies of 5–40 ms occur under load or during storage-side
garbage collection. A single unlucky fsync burst can inflate the overhead
well beyond the average.

| Storage | Typical fsync | 300 fsyncs (300K rows) | 100K fsyncs (100M rows) |
|---------|---------------|------------------------|-------------------------|
| Local NVMe | ~1 ms | ~300 ms | ~100 s |
| Pure Storage (our test env) | ~1 ms median, 5–40 ms tail | ~300 ms – 2 s | **2–20 min** |
| OpenStack Cinder | 5–40 ms | 1.5–12 s | **8 min – 1 h** |
| Cloud EBS gp3 | 2–10 ms | 0.6–3 s | **3–17 min** |

With network-attached storage, the effect becomes dramatically worse at
production table sizes because tail latencies compound over thousands of
sequential fsyncs.

**Scale**: 100 M-row table → ~100,000 fsyncs per VACUUM FULL replay —
minutes to hours of stall depending on storage fsync latency.

---

### S14 — Replay throughput saturation (50-row scattered × 11 idx)

```bash
bash run.sh 14   # ~15 min (8 concurrency levels × 2 modes × 20 s each + catchup)
```

**Setup**: `saturation_test` table (500 K rows, 10 secondary indexes + PK).
Each transaction updates 50 rows **scattered** 10,000 apart, modifying all
indexed columns — touching all 11 indexes per row (non-HOT).

**What it does**: Runs pgbench at 1, 2, 4, 8, 16, 32, 64, then 128 clients
under each sync mode (20 s per level). Prints a concurrency vs latency table
for both modes side by side.

**Mechanism**: WAL replay is **single-threaded**. Each commit generates
50 scattered rows × 11 indexes = ~550 distinct page modifications → ~300 KB
WAL per commit. As primary concurrency grows, combined WAL generation from all
clients exceeds single-threaded replay throughput. Under `remote_apply`, each
commit must wait in a growing queue. Under `remote_write`, commits only wait
for WAL bytes to arrive in standby memory.

**What to look for**:
```
  clients   remote_write   remote_apply   added_ms
  -------   ------------   ------------   --------
        1          25.0           26.5       +1.5
        4          26.1           30.8       +4.7
       16          28.0           42.4      +14.4
       32          30.1           60.3      +30.2
       64          35.5           95.6      +60.1
      128          45.2          165.8     +120.6
```
`remote_write` latency stays flat or grows slowly (CPU contention).
`remote_apply` latency grows faster — the gap (`added_ms`) increasing with
client count is the signature of replay queuing.

**Typical result**: growing `added_ms` with concurrency; magnitude scales with
server CPU count and WAL-per-transaction

**Scale**: a 128-CPU server running thousands of TPS can generate 1+ GB/s of
WAL, exceeding NVMe replay throughput (~200–500 MB/s). Every `remote_apply`
commit then waits for an ever-growing queue — a failure mode that simply does
not exist under `remote_write`.

---

---

## Non-default scenarios

These can be run explicitly but are not included in `bash run.sh`:

### S15 — Anti-wraparound VACUUM (zero conflicts)

```bash
bash run.sh 15   # ~15 min (5 M-row table load, then 2× UPDATE + CHECKPOINT + VACUUM FREEZE)
```

**Why not in defaults**: VACUUM FREEZE on a 5 M-row table generates WAL at
~40 MB/s, but single-threaded replay handles 500+ MB/s on modern hardware.
The effect only manifests with very large tables (100 GB+) where the sheer
WAL volume exceeds replay throughput.

**Mechanism**: Anti-wraparound autovacuum generates WAL proportional to table
size at full I/O speed. A `CHECKPOINT` before VACUUM FREEZE amplifies WAL
(8 KB FPI per page). Under `remote_apply`, each commit must wait for
preceding VACUUM WAL to be replayed.

**Scale** (where the scenario matters):

| Table size | FPI WAL | Replay at 300 MB/s | `remote_apply` stall |
|------------|---------|---------------------|----------------------|
| 100 GB | ~100 GB | ~5 min | **5 min per anti-wraparound** |
| 1 TB | ~1 TB | ~55 min | **55 min per anti-wraparound** |
| 10 TB | ~10 TB | ~9 h | **9 hours per anti-wraparound** |

Every `remote_apply` commit issued during that window waits. This is a
recurring, automatic, unavoidable event on long-lived large tables.

### S9 — Buffer pin contention (VACUUM FREEZE)

```bash
bash run.sh 9   # ~7 min
```

**Why not in defaults**: `XLOG_HEAP2_FREEZE_PAGE` replay uses
`XLogReadBufferForRedo()` (regular exclusive content lock), **not**
`LockBufferForCleanup()`. Buffer pins from concurrent scanners do not
block it. Only `HEAP2_PRUNE` and `BTREE_VACUUM` records need cleanup
locks, but `hot_standby_feedback = on` typically prevents their generation
(standby xmins prevent dead-tuple removal on the primary).

Buffer pin conflicts are real in production (visible in
`pg_stat_database_conflicts.confl_bufferpin`), but they require specific
WAL record types that are hard to generate reliably in a benchmark.

### S5 — Bulk INSERT / ETL load

```bash
bash run.sh 5   # ~4 min
```

Single large INSERT (500 K rows). Added latency depends on standby I/O
throughput but is typically < 5 ms on fast storage.

### S6 — FPI storm (frequent checkpoints)

```bash
bash run.sh 6   # ~4 min
```

Full Page Image amplification after checkpoints. The effect scales with
`shared_buffers` size. In a symmetric benchmark config (same `shared_buffers`
on primary and standby), FPI replay is fast (~300–500 MB/s on NVMe) because
FPI application is a simple page overwrite — no read-modify-write needed. The
self-regulating nature of `remote_apply` (TPS drops → less WAL → replay catches
up) prevents sustained backlog buildup.

This is a real production problem at **scale** (64+ GB `shared_buffers`,
terabytes of data, bulk jobs touching millions of pages after checkpoint), but
cannot be reliably demonstrated on a small benchmark.

### S13 — Hash index VACUUM (snapshot + cleanup lock)

```bash
bash run.sh 13   # ~5 min
```

Dual conflict mechanism (`ResolveRecoveryConflictWithSnapshot` +
`LockBufferForCleanup`) exists in code but the overlap window is too narrow
for reliable demonstration. Typical result: +1–5 ms.

---

## Effect of `hot_standby_feedback`

| Scenario | Type | `hsf=off` | `hsf=on` |
|----------|------|-----------|----------|
| S2 Snapshot conflict | snapshot | BLOCKED | **prevented** |
| S7 Cross-table blast | snapshot | BLOCKED | **prevented** |
| S8 VACUUM FULL | lock conflict | BLOCKED | **no effect** |
| S12 Logical rewrite fsyncs | I/O overhead | adds ms | **no effect** |
| S10 Large UPDATE | replay throughput | adds ms | **no effect** |
| S11 DROP partitions | fs ops on replay | adds ms | **no effect** |
| S14 Replay saturation | WAL gen > replay rate | grows with concurrency | **no effect** |
| S15 Anti-wraparound VACUUM* | WAL volume (FREEZE+FPI) | hours at 1 TB scale | **no effect** |

`hot_standby_feedback = on` prevents snapshot conflicts by advertising the
standby's oldest active xmin to the primary, causing VACUUM to skip rows that
active standby transactions still need. This eliminates the WAL records that
trigger snapshot conflict resolution.

**The cost**: the primary's VACUUM cannot clean dead rows that any open standby
transaction might theoretically need, even if those transactions never actually
read that table. Long-running analytics queries on the standby will cause dead
tuple accumulation and table bloat on the primary. This is the fundamental
tradeoff: use `hsf=on` to protect against snapshot-conflict stalls; accept
bloat risk.

Lock conflicts (S8) and all non-conflict replay overhead (S10–S12, S14)
are unaffected regardless of this setting.
(*S9 and S15 are non-default scenarios — see their entries for details.)

---

## Interpreting Results

```
  #    Scenario                                rw_ms     ra_ms  added_ms
  ─────────────────────────────────────────────────────────────────────
     2  Blocked replay (snapshot conflict)      BLOCKED ← 0 TPS for 65/70s (340x TPS drop)
     7  Reporting query (cross-table blast)     BLOCKED ← 0 TPS for 80/85s (350x TPS drop)
     8  Table rewrite / lock conflict           BLOCKED ← 0 TPS for 60/70s (170x TPS drop)
     1  Index-heavy scattered UPDATE (100 rows)  110.2     149.6    +39.4
     3  GIN + TOAST batch (30 rows scattered)   108.4     119.7    +11.3
     4  Schema migration (wall clock)                3      4200    +4197
    12  VACUUM FULL + logical slot              2197      2533     +336
```

- **BLOCKED**: `remote_apply` commits completely frozen (0 TPS) for the
  indicated duration. The benchmark reports this instead of misleading average
  latency (pgbench's average only counts *completed* transactions, hiding the
  freeze).
- **`added_ms = ra_ms − rw_ms`** — the pure overhead of waiting for replay
  vs just waiting for WAL to be written to standby memory.
- A small positive value (< 20 ms) reflects normal inter-server RTT and
  replay throughput on your hardware.
- A large spike indicates one of the blocking mechanisms described above.
- `remote_write` latency is your floor — it represents the network round trip
  plus standby write time and cannot be reduced without moving the standby
  closer.

Results in `RESULTS_DIR` (default `/tmp/syncrep_results`) include per-5-second
pgbench progress lines so you can see latency evolve over the scenario
duration, not just the average.

---

## Repository Layout

```
syncrep.conf.example          connection config template
run.sh                        run all scenarios (or a range)
report.sh                     parse result files → summary table
setup_patroni_env.sh          pre-flight cluster health check

scenario{1-15}*/              SQL files for each scenario
  setup.sql                   table creation and data loading
  workload.sql                pgbench transaction script
  standby_*.sql               queries run on the standby (blockers/scanners)

infra/                        optional: provision fresh VMs on Hetzner Cloud
  hetzner.conf.example        config template (copy → hetzner.conf)
  hetzner_create.sh           create two VMs + private network
  init_cluster.sh             install PG + Patroni, form sync cluster
  setup_node.sh               per-node bootstrap (called by init_cluster.sh)
  hetzner_destroy.sh          tear down all provisioned resources
```
