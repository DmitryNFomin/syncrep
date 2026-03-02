# remote_write vs remote_apply — Latency Benchmark Suite

Demonstrates **when and why** `synchronous_commit = remote_apply` adds latency
compared to `remote_write` on a live PostgreSQL synchronous-replication cluster.

Thirteen scenarios cover every distinct mechanism: snapshot conflicts, lock
conflicts, buffer-pin stalls, WAL replay throughput, and per-record fsync
overhead. Each scenario is self-contained and leaves no persistent state.

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

### Latency sources at a glance

| Scenario | Mechanism | Magnitude | `hsf=on` fixes it? |
|----------|-----------|-----------|---------------------|
| S2 Snapshot conflict | Replay stall (snapshot) | **20×** | Yes |
| S7 Cross-table blast | Replay stall (snapshot) | **350×** | Yes |
| S8 VACUUM FULL lock | Replay stall (lock) | **170×** | **No** |
| S9 Buffer pin | Replay stall (buffer pin) | ~5 ms | **No** |
| S13 Hash VACUUM | Replay stall (snapshot + pin) | ~1 ms | Mostly |
| S10 Large UPDATE | WAL replay throughput | ~350 ms | **No** |
| S12 Logical rewrite | pg_fsync per rewrite record | ~70 ms | **No** |
| S11 DROP partitions | unlink() per file on replay | ~50 ms | **No** |
| S4 CREATE INDEX | Index build on replay | ~17 ms | **No** |
| S5 Bulk INSERT | WAL replay throughput | ~15 ms | **No** |
| S6 FPI storm | WAL volume (full-page images) | ~10 ms | **No** |
| S1 Normal OLTP | Baseline RTT + replay | ~5 ms | — |
| S3 GIN/TOAST | WAL volume (bursty records) | ~1 ms | — |

**Key insight**: `hot_standby_feedback = on` prevents only snapshot conflicts
(S2, S7, S13). Lock conflicts (S8), buffer-pin stalls (S9), and all
non-conflict replay overhead (S4–S6, S10–S12) are unaffected — because they
have nothing to do with row visibility. See [Effect of
`hot_standby_feedback`](#effect-of-hot_standby_feedback) for the full
tradeoff including the bloat cost.

---

## Prerequisites

- Two PostgreSQL servers (primary + synchronous standby) with Patroni
- `synchronous_mode: true` in Patroni config (or `synchronous_standby_names`
  set manually in `postgresql.conf`)
- `pgbench` available on the machine running the benchmarks (same major
  version as the server, or close)
- Network access to both servers on port 5432

### Standby configuration

Two settings must be tuned before running (on the **standby**):

```sql
-- Without this, standby cancels conflicting queries immediately,
-- making conflict scenarios (S2, S7, S8, S9, S13) useless.
ALTER SYSTEM SET max_standby_streaming_delay = '-1';

-- Without this, the standby tells the primary which XIDs are still active,
-- causing VACUUM to delay — which suppresses the conflict WAL the
-- snapshot scenarios depend on.
ALTER SYSTEM SET hot_standby_feedback = off;

SELECT pg_reload_conf();
```

See "Effect of hot_standby_feedback" at the bottom for the full tradeoff.

---

## Quick Start

```bash
# 1. Clone and configure
git clone <repo>
cd syncrep
cp syncrep.conf.example syncrep.conf
$EDITOR syncrep.conf          # fill in IPs, credentials

# 2. Verify cluster connectivity and sync state
source syncrep.conf && bash setup_patroni_env.sh

# 3. Run all 13 scenarios
bash -c "set -a; source syncrep.conf; set +a; bash run.sh"

# 4. Run a subset (e.g. scenarios 1 through 5)
bash -c "set -a; source syncrep.conf; set +a; bash run.sh 1 5"

# 5. Print summary report from saved results
bash -c "set -a; source syncrep.conf; set +a; bash report.sh"
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

Each scenario runs the measured workload twice — once with
`synchronous_commit = remote_write`, once with `remote_apply` — and reports
the difference. The `bench` database and all test tables are created
automatically.

---

### S1 — Index-heavy UPDATE saturation

**What**: Steady pgbench workload against a table with six B-tree indexes.
Heavy write amplification from index maintenance generates a continuous stream
of WAL.

**Why latency increases**: Under normal load with no standby conflicts,
`remote_apply` adds only the replay latency for routine DML WAL. This scenario
establishes the baseline overhead.

**Typical result**: +4–6 ms (≈ network RTT between primary and standby)

---

### S2 — Snapshot conflict (blocked replay)

**What**: A `REPEATABLE READ` transaction runs a long aggregate on the standby
while the primary runs a churning UPDATE + VACUUM loop that generates
`XLOG_HEAP2_PRUNE_FREEZE` WAL (dead row pruning).

**Mechanism**:
1. Standby query opens a snapshot at time T.
2. Primary's VACUUM prunes rows that were dead after T but the standby snapshot
   still needs for consistency.
3. Replay calls `ResolveRecoveryConflictWithSnapshot()`.
4. With `max_standby_streaming_delay = -1`, replay waits until the standby
   query finishes (up to 90 s in this scenario).
5. Every primary commit during the wait blocks under `remote_apply`.

**Why `remote_write` is unaffected**: `remote_write` only waits for WAL bytes
to arrive in the standby's memory. Replay is completely decoupled from the
write acknowledgement — conflicts don't matter.

**Typical result**: +2000 ms (20×); spikes to full query duration on longer
standby queries

---

### S3 — GIN + TOAST bursty replay

**What**: Inserts of large text documents with GIN full-text indexing and TOAST
storage. GIN pending-list flushes and TOAST chunk inserts produce bursty, large
WAL records.

**Why latency increases**: Large WAL records take longer to replay (more pages
to write). With no standby conflicts, the overhead is proportional to WAL size
and I/O speed.

**Typical result**: +1–3 ms (marginal on fast local SSDs)

---

### S4 — Schema migration (CREATE INDEX CONCURRENTLY)

**What**: Creates a B-tree index on a 500K-row table while pgbench continues
running.

**Why latency increases**: Replay of the index build WAL must reconstruct the
entire index on the standby. This is purely sequential work — no conflict, just
time. Commit latency during the index build reflects standby replay throughput.

**Typical result**: +15–30 ms; larger on bigger tables or slower standby I/O

---

### S5 — Bulk INSERT / ETL load

**What**: Inserts 500K rows in a single transaction (simulating an ETL job).

**Why latency increases**: One large transaction generates a large WAL segment.
The primary issues the commit ACK only after the standby replays the entire
segment. Replay time scales with row count and table structure.

**Typical result**: +10–20 ms; scales linearly with transaction size

---

### S6 — FPI storm (frequent checkpoints)

**What**: Triggers aggressive checkpointing (`checkpoint_completion_target` at
minimum) while running normal OLTP. The first write to any dirty page after a
checkpoint generates a Full Page Image in WAL — roughly 8 KB per page vs ~50
bytes for a normal WAL record.

**Why latency increases**: FPIs inflate WAL volume by 10–100× for a short
burst. Replay must write complete pages, not just diffs. The standby's I/O
throughput becomes the bottleneck.

**Typical result**: +5–15 ms during the FPI burst

---

### S7 — Reporting query blocks replay (cross-table blast radius)

**What**: A `REPEATABLE READ` analytics query runs on the standby against the
`orders` table. The primary runs VACUUM on `orders`, generating prune WAL.

**Why this is worse than S2**: Snapshot conflicts stall the **entire** replay
stream, not just WAL for the conflicting table. During the stall, commits to
*any* table on the primary queue up waiting for `remote_apply`. A single
reporting query on the standby freezes all primary commits regardless of what
table they touch.

**Typical result**: +30 000–40 000 ms (300–400×) — full query duration stall
propagates to every concurrent transaction on the primary

---

### S8 — Table rewrite / lock conflict

**What**: A SELECT runs on the standby against `bloated`. The primary runs
`VACUUM FULL bloated`, which rewrites the table and acquires
`AccessExclusiveLock`.

**Mechanism**: Unlike regular VACUUM (snapshot conflict), `VACUUM FULL`
produces lock conflict WAL. Replay calls `ResolveRecoveryConflictWithLock()`.
The standby's `AccessShareLock` (held by the SELECT) conflicts with the
replayed `AccessExclusiveLock`. Replay stalls until the SELECT finishes or is
cancelled.

**Why `hot_standby_feedback` does not help**: Feedback prevents snapshot
conflicts by delaying VACUUM from pruning needed rows. It has no effect on
lock-type conflicts — `VACUUM FULL` will still request `AccessExclusiveLock`
regardless of what the standby reports.

**Typical result**: +20 000–25 000 ms (150–170×)

---

### S9 — Buffer pin contention (VACUUM FREEZE replay)

**What**: 20 parallel full-table scans run on the standby (pinning pages),
while the primary runs a `VACUUM FREEZE` loop.

**Mechanism**: `XLOG_HEAP2_FREEZE_PAGE` replay calls
`XLogReadBufferForRedoExtended(..., get_cleanup_lock=true)`, which calls
`LockBufferForCleanup()`. This waits for all pins on the buffer to drop. With
20 concurrent scans, the probability that any given page is pinned at some
moment is non-trivial — each pin collision adds a brief wait.

**Character**: Unlike S2/S7/S8 (full stall), this produces many small
incremental delays rather than one long pause. Effect is more visible as
elevated stddev and tail latency.

**Typical result**: +3–10 ms average; effect is stronger in p99

---

### S10 — Large synchronous UPDATE

**What (part A — pgbench)**: pgbench runs a workload where each transaction
updates a large fraction of a table. Measures average per-transaction latency
as WAL volume per commit grows.

**What (part B — wall clock)**: A single full-table UPDATE in one transaction.
Measures wall-clock time for the single commit to complete.

**Why latency increases (part A)**: Each large-table UPDATE transaction
produces proportionally more WAL. `remote_apply` must wait for all of it to
replay before the commit returns. As row count per transaction grows, the gap
between `remote_write` and `remote_apply` widens linearly.

**Part B note**: The single-transaction wall clock includes both primary
execution time and standby replay time. On identical hardware these can be
close, and results vary run-to-run.

**Typical result (A)**: +300–400 ms; **(B)**: near-zero difference or noise

---

### S11 — DROP TABLE on partitioned table (50 partitions)

**What**: Creates a 50-partition table, then measures wall-clock time to `DROP`
it under each sync mode.

**Why latency increases**: `DROP TABLE` on a partitioned table generates one
`XLOG_SMGR_TRUNCATE` or equivalent record per relation. During replay, each
record triggers `RelationDropStorage()` — a filesystem `unlink()` call. With 50
partitions, that is 50+ sequential filesystem operations on the standby during a
single commit replay. The primary waits for all of them under `remote_apply`.

**Typical result**: +40–60 ms (scales with partition count)

---

### S12 — VACUUM FULL with logical replication slot

**What**: Creates a logical replication slot, bloats a 300K-row table, then
runs `VACUUM FULL`. Measures wall-clock time for the VACUUM FULL commit.

**Mechanism** (`rewriteheap.c:heap_xlog_logical_rewrite`):
When `wal_level = logical` and at least one logical slot exists, `VACUUM FULL`
and `CLUSTER` write `XLOG_HEAP2_REWRITE` records — old→new TID mappings needed
for logical decoding to track row identity across rewrites.

During replay, `heap_xlog_logical_rewrite()` calls `pg_fsync(fd)` after
**every single record**, not at the end of the operation. For a 300K-row table
this means ~300 individual fsyncs during replay of a single VACUUM FULL commit.

**Without** a logical slot: no `XLOG_HEAP2_REWRITE` records are written;
`VACUUM FULL` completes at the same speed under both modes.

**Typical result**: +60–100 ms per VACUUM FULL; scales with table size and
row count

---

### S13 — Hash index VACUUM (snapshot + cleanup lock combined)

**What**: A `REPEATABLE READ` transaction plus concurrent bucket-page scans run
on the standby while the primary runs `VACUUM` on a hash-indexed table with
dead entries.

**Mechanism** (`hash_xlog.c:hash_xlog_vacuum_one_page`):
`XLOG_HASH_VACUUM_ONE_PAGE` is unique in calling **both** conflict mechanisms
sequentially:
1. `ResolveRecoveryConflictWithSnapshot(snapshotConflictHorizon)` — waits for
   standby snapshots older than the conflict horizon to close
2. `XLogReadBufferForRedoExtended(..., get_cleanup_lock=true)` — waits for all
   pins on the bucket page to drop

S2/S7 use only step 1; S9 uses only step 2; S13 requires both simultaneously.

**Typical result**: +1–5 ms on current PG versions; the dual mechanism is
theoretically more aggressive but in practice the overlap window is small

---

## Effect of `hot_standby_feedback`

| Scenario | Type | `hsf=off` | `hsf=on` |
|----------|------|-----------|----------|
| S2 Snapshot conflict | snapshot | stalls | **prevented** |
| S7 Cross-table blast | snapshot | stalls | **prevented** |
| S13 Hash VACUUM | snapshot + pin | stalls | mostly prevented |
| S8 VACUUM FULL | lock conflict | stalls | **no effect** |
| S9 Buffer pin | buffer pin | minor stall | **no effect** |
| S12 Logical rewrite fsyncs | I/O overhead | adds ms | **no effect** |
| S10 Large UPDATE | replay throughput | adds ms | **no effect** |
| S11 DROP partitions | fs ops on replay | adds ms | **no effect** |

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

Lock conflicts (S8), buffer-pin conflicts (S9), and all non-conflict replay
overhead (S10–S13) are unaffected regardless of this setting.

---

## Interpreting Results

```
  #    Scenario                                rw_ms     ra_ms  added_ms
  ─────────────────────────────────────────────────────────────────────
     2  Blocked replay (snapshot conflict)      107.6    2141.4   +2033.9
     7  Reporting query (cross-table blast)     109.7   38233.2  +38123.5
     8  Table rewrite / lock conflict           144.5   24325.7  +24181.3
```

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

scenario*/                    SQL files for each scenario
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
