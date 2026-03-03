# remote_write vs remote_apply — Latency Benchmark Suite

Demonstrates **when and why** `synchronous_commit = remote_apply` adds latency
compared to `remote_write` on a live PostgreSQL synchronous-replication cluster.

Fifteen scenarios cover every distinct mechanism: snapshot conflicts, lock
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

### Latency sources at a glance

| Scenario | Mechanism | Magnitude | `hsf=on` fixes it? |
|----------|-----------|-----------|---------------------|
| S2 Snapshot conflict | Replay stall (snapshot) | **20×** | Yes |
| S7 Cross-table blast | Replay stall (snapshot) | **350×** | Yes |
| S8 VACUUM FULL lock | Replay stall (lock) | **170×** | **No** |
| S9 Buffer pin | Replay stall (buffer pin) | ~5 ms | **No** |
| S13 Hash VACUUM | Replay stall (snapshot + pin) | ~1 ms | Mostly |
| S10 Large UPDATE | WAL replay throughput | ~350 ms | **No** |
| S15 Anti-wraparound VACUUM | WAL volume (FREEZE + FPI) | **hours at 1 TB** | **No** |
| S12 Logical rewrite | pg_fsync per rewrite record | scales with rows | **No** |
| S11 DROP partitions | unlink() per file on replay | scales with N parts | **No** |
| S14 Replay saturation | WAL gen > single-thread replay | grows with CPU count | **No** |
| S4 CREATE INDEX | Index build on replay | ~17 ms | **No** |
| S5 Bulk INSERT | WAL replay throughput | ~15 ms | **No** |
| S6 FPI storm | WAL volume (full-page images) | **minutes at 75 GB shbuf** | **No** |
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
SHOW wal_level;   -- 'logical' for S12, 'replica' is fine for S1–S11, S13–S15
```

### Standby configuration (handled automatically)

`setup_patroni_env.sh` sets these on the standby — you do not need to set them
manually:

```sql
-- Wait forever on conflicts instead of cancelling standby queries.
-- Required for conflict scenarios (S2, S7, S8, S9, S13) to be meaningful.
ALTER SYSTEM SET max_standby_streaming_delay = '-1';

-- Prevent the standby from suppressing VACUUM on the primary.
-- Required for snapshot-conflict scenarios (S2, S7, S13) to generate
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

# 3. Run all 15 scenarios
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

**Run all scenarios** (≈ 90 min total):
```bash
bash run.sh
```

**Run one scenario**:
```bash
bash run.sh 7        # just S7
bash run.sh 2 7 8    # S2, S7, and S8 — the three dramatic conflict cases
```

**Watch results build up** in a second terminal:
```bash
bash report.sh       # re-run any time; reads whatever result files exist
```

---

### S1 — Index-heavy UPDATE saturation

```bash
bash run.sh 1   # ~3 min
```

**Setup**: 2 M-row table with 6 B-tree indexes, fillfactor 50. Scattered
UPDATEs force index maintenance on nearly every page.

**What it does**: Runs a 60 s pgbench workload at 24 clients under each sync
mode. No standby blockers — this is the clean baseline.

**Why latency increases**: Routine DML WAL must be replayed before each commit
ACK under `remote_apply`. The added latency equals approximately one network
RTT between primary and standby (the time for the replay ACK to travel back).

**What to look for**:
```
avg latency (ms)       remote_write   remote_apply
                            110.2          115.1
Added latency: +4.9 ms    MARGINAL
```
The per-5 s progress lines (printed during the run) should all stay stable —
no spikes. This is your floor for every other scenario.

**Typical result**: +4–6 ms

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
avg latency (ms)     remote_write   remote_apply
                          107.6         2141.4
Added latency: +2033.9 ms    20×    PASS
```
Watch the per-5 s progress lines during `remote_apply` — latency should jump
from ~110 ms to 1000–3000 ms immediately when the blocker starts, then drop
back when the standby query finishes. The `replay_lag` column in
`pg_stat_replication` will show the growing WAL backlog.

**Typical result**: +2000 ms (20×)

---

### S3 — GIN + TOAST bursty replay

```bash
bash run.sh 3   # ~4 min
```

**Setup**: `tickets` table with four GIN indexes (text search, trigrams, tags
array, metadata jsonb). Rows contain 1–5 KB of text stored via TOAST.

**What it does**: Inserts large text documents via pgbench (30 s, 8 clients).
GIN pending-list flushes produce large, bursty WAL records; TOAST chunks
generate many small records per row.

**Why latency increases**: Large WAL records take longer to replay — more page
writes per record. The overhead is proportional to WAL record size and standby
I/O throughput. No conflict involved.

**What to look for**: Per-5 s progress lines that are slightly uneven — bursty
WAL causes small latency spikes when GIN flushes its pending list.

**Typical result**: +1–3 ms (marginal on fast SSDs)

---

### S4 — Schema migration (CREATE INDEX CONCURRENTLY)

```bash
bash run.sh 4   # ~5 min
```

**Setup**: `events` table (500 K rows, 4 columns). A probe table (`probe_s4`)
takes the latency measurement while the index builds.

**What it does**: Runs `CREATE INDEX CONCURRENTLY` on the primary while
simultaneously running a pgbench workload (30 s, 8 clients on `probe_s4`).

**Why latency increases**: Replay must rebuild the entire index from the WAL
on the standby. This is sequential, I/O-bound work — no conflict, just time.
Every commit during index build replay waits.

**What to look for**: A consistent latency elevation for the full duration of
the CREATE INDEX (visible in progress lines), dropping back to baseline after
the index is built. The `replay_lag` bytes column in `pg_stat_replication` will
stay elevated while the index WAL replays.

**Typical result**: +15–30 ms during index build; larger on bigger tables

---

### S5 — Bulk INSERT / ETL load

```bash
bash run.sh 5   # ~4 min
```

**Setup**: `logs` table (500 K rows pre-loaded, 4 indexes). A probe table
(`probe_s5`) measures latency during the bulk load.

**What it does**: Inserts 500 K rows in a single transaction (one large commit)
while probing primary latency with pgbench (30 s, 8 clients).

**Why latency increases**: The single large INSERT generates one large WAL
segment. The primary can only issue the commit ACK after the standby replays
the entire segment end-to-end. Replay time scales with row count.

**What to look for**: A single large latency spike in the progress lines when
the bulk commit lands, then return to normal. Under `remote_write`, the bulk
commit returns as soon as WAL bytes land in standby memory — no spike.

**Typical result**: +10–20 ms during the bulk commit; scales linearly with rows

---

### S6 — FPI storm (frequent checkpoints)

```bash
bash run.sh 6   # ~4 min
```

**Setup**: 2 M-row table (`wide_table`) with fillfactor 50. `checkpoint_timeout`
is reduced to 30 s for the duration of the scenario.

**What it does**: Runs pgbench (60 s, 24 clients) with aggressive checkpoints.
After each checkpoint, the first write to any dirty page emits an 8 KB full-page
image (FPI) rather than a ~50-byte diff WAL record — inflating WAL volume
10–100×.

**Why latency increases**: Replay must write complete 8 KB pages instead of
applying small diffs. The standby's I/O throughput becomes the bottleneck.
FPI bursts cause periodic latency spikes rather than a steady increase.

**What to look for**: Latency spikes in the per-5 s progress lines immediately
after each checkpoint (every 30 s). Between spikes, latency returns to near
`remote_write` levels. The `lag_bytes` column in `pg_stat_replication` will
show a sawtooth pattern — growing during FPI bursts, draining between them.

**Typical result**: +5–15 ms during FPI bursts

**Scale**: effect grows directly with `shared_buffers`. At 75 GB
`shared_buffers` (typical for a 300 GiB server), a post-checkpoint FPI storm
can generate 10–75 GB of WAL. At 300 MB/s replay throughput: 30–250 seconds
of stall for every `remote_apply` commit during that window.

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
avg latency (ms)     remote_write   remote_apply
                          109.7        38233.2
Added latency: +38123.5 ms   349×    PASS
```
Watch `pg_stat_replication` during the run — `replay_lag` will show hours or
days (the standby has completely stopped replaying), while `write_lag` and
`flush_lag` stay at milliseconds. This gap is the visible signature of a replay
stall.

**Typical result**: +30 000–40 000 ms (300–400×)

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

**What to look for**: Same pattern as S7 — `replay_lag` in `pg_stat_replication`
shows hours while the blocker holds. Latency in the progress lines jumps to
10 000–30 000 ms for the duration of the VACUUM FULL.

**Typical result**: +20 000–25 000 ms (150–170×)

---

### S9 — Buffer pin contention (VACUUM FREEZE replay)

```bash
bash run.sh 9   # ~7 min
```

**Setup**: `freeze_test` table (300 K rows, ~60 MB). A probe table (`probe_s9`)
takes the latency measurement.

**What it does**:
1. Starts 20 parallel full-table sequential scans on the standby — each scan
   briefly pins every page it reads.
2. Runs a VACUUM FREEZE loop on the primary (8 iterations, local sync).
3. Simultaneously probes primary commit latency (45 s).

**Mechanism**: `XLOG_HEAP2_FREEZE_PAGE` replay calls `LockBufferForCleanup()`,
which waits for all pins on that buffer to drop. With 20 concurrent scans,
there is sustained pin pressure — each page collision adds a small wait.
Stalls are many and brief, not one long pause.

**Character**: Unlike S2/S7/S8 (complete stall), this produces many small
per-page delays that aggregate. Effect shows most clearly as elevated latency
stddev and p99, not necessarily in the average.

**What to look for**: Slightly uneven progress lines with higher stddev than
S1. The `replay_lag` bytes will oscillate — rising when pins collide, draining
between collisions. Not a single clean spike.

**Typical result**: +3–10 ms average; stronger effect in p99

**Scale**: more pages = more FREEZE_PAGE records = more pin collision
opportunities per VACUUM FREEZE pass. For the pure WAL-volume aspect of
anti-wraparound at production scale, see S15.

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
  remote_write:  1640 ms    WAL generated: 45 MB
  remote_apply:  1712 ms    WAL generated: 45 MB    (+72 ms)
```
Both modes generate the same WAL; the difference is entirely the standby
spending time calling `pg_fsync()` on mapping files.

**Typical result**: +60–100 ms; scales with table size and row count

**Scale**: 100 M-row table → ~100,000 fsyncs per VACUUM FULL replay —
seconds to minutes of stall every time the table is vacuumed.

---

### S13 — Hash index VACUUM (snapshot + cleanup lock combined)

```bash
bash run.sh 13   # ~5 min
```

**Setup**: `hash_test` table (200 K rows) with a hash index and 100 K dead
tuples. A probe table (`probe_s13`) takes the latency measurement.

**What it does**:
1. Starts a `REPEATABLE READ` blocker (holds old snapshot) on the standby.
2. Starts concurrent bucket-page scans on the standby (buffer pin pressure).
3. Runs `VACUUM hash_test` on the primary to generate `XLOG_HASH_VACUUM_ONE_PAGE` WAL.
4. Measures primary commit latency during the above.

**Mechanism** (`hash_xlog.c:hash_xlog_vacuum_one_page`): This WAL record type
is unique in calling **both** conflict mechanisms sequentially:
1. `ResolveRecoveryConflictWithSnapshot()` — waits for old snapshots to close
2. `LockBufferForCleanup()` — waits for all bucket-page pins to drop

S2/S7 trigger only step 1; S9 triggers only step 2; S13 requires both.

**What to look for**: A small added latency — the dual mechanism exists in the
code but the overlap window (snapshot held *and* page pinned simultaneously) is
narrow in practice.

**Typical result**: +1–5 ms

---

### S14 — Replay throughput saturation (high-concurrency ceiling)

```bash
bash run.sh 14   # ~12 min (6 concurrency levels × 2 modes × 20 s each + catchup)
```

**Setup**: `saturation_test` table (100 K wide rows — ~500 bytes each). Each
transaction updates one row, mutating both text columns (~3–5 KB WAL/txn).

**What it does**: Runs pgbench at 1, 2, 4, 8, 16, then 32 clients under each
sync mode (20 s per level). Prints a concurrency vs latency table for both
modes side by side.

**Mechanism**: WAL replay is **single-threaded**. As primary concurrency grows,
WAL generation rate climbs. Under `remote_apply`, each commit must wait for
its own WAL to be replayed — and the replay thread is shared by all concurrent
commits. Under `remote_write`, commits only wait for WAL bytes to arrive in
standby memory, which is independent of replay.

**What to look for**:
```
  clients   remote_write   remote_apply   added_ms
  -------   ------------   ------------   --------
        1         112.1          113.4       +1.3
        4         113.2          116.8       +3.6
       16         115.0          128.4      +13.4
       32         118.1          147.3      +29.2
```
`remote_write` latency stays flat or grows slowly (CPU contention).
`remote_apply` latency grows faster — the gap (`added_ms`) increasing with
client count is the signature of replay queuing.

On a small VM, the divergence may be subtle. The number to watch is whether
`added_ms` **grows monotonically** with client count — that's the signal, even
if the absolute magnitude is small.

**Typical result**: growing `added_ms` with concurrency; magnitude scales with
server CPU count and WAL-per-transaction

**Scale**: a 128-CPU server running thousands of TPS can generate 1+ GB/s of
WAL, exceeding NVMe replay throughput (~200–500 MB/s). Every `remote_apply`
commit then waits for an ever-growing queue — a failure mode that simply does
not exist under `remote_write`.

---

### S15 — Anti-wraparound VACUUM (large WAL volume, zero conflicts)

```bash
bash run.sh 15   # ~15 min (2 M-row table load ~60 s, then 2× UPDATE + CHECKPOINT + VACUUM FREEZE)
```

**Setup**: `antiwrap_test` table (2 M rows, ~700 MB on disk: bigint PK +
md5 payload + 300-char filler).

**What it does**:
1. Updates 50% of rows (creates unfrozen tuples for VACUUM FREEZE to process).
2. Runs `CHECKPOINT` — marks all pages "clean" so the next write emits a
   full-page image (FPI).
3. Runs `VACUUM FREEZE antiwrap_test` with `vacuum_freeze_min_age = 0` —
   forces it to process every page, emitting both a `XLOG_HEAP2_FREEZE_PAGE`
   record **and** an 8 KB FPI per page.
4. Measures wall-clock time for the commit to return under each sync mode.
5. Reports total WAL generated.

No standby queries run. This is a pure replay throughput test — no conflicts.

**Mechanism**: Anti-wraparound autovacuum triggers when `relfrozenxid` is close
to `autovacuum_freeze_max_age` (default 200 M transactions), bypasses
`autovacuum_vacuum_cost_delay` (runs at full I/O speed), and cannot be
cancelled. The FPI amplification makes WAL volume ≈ table size.

Under `remote_write`, the commit returns immediately — replay happens async in
the background. Under `remote_apply`, the primary blocks until the standby has
replayed every FREEZE_PAGE + FPI record.

**What to look for**:
```
  remote_write:   3241 ms    WAL generated: 712 MB
  remote_apply:   7854 ms    WAL generated: 712 MB    (+4613 ms)
```
Both modes show the same WAL volume (the WAL is generated by the primary
regardless of sync mode). The difference is entirely the standby's replay time.
Dividing `added_ms` by the WAL size gives your standby's effective replay
throughput for FPI-heavy workloads.

**Typical result**: ~4–10 s added latency on a 700 MB table (depends on
standby I/O throughput)

**Scale**:

| Table size | FPI WAL | Replay at 300 MB/s | `remote_apply` stall |
|------------|---------|---------------------|----------------------|
| 100 GB | ~100 GB | ~5 min | **5 min per anti-wraparound** |
| 1 TB | ~1 TB | ~55 min | **55 min per anti-wraparound** |
| 10 TB | ~10 TB | ~9 h | **9 hours per anti-wraparound** |

Every `remote_apply` commit issued during that window waits. This is a
recurring, automatic, unavoidable event on long-lived large tables.

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
| S14 Replay saturation | WAL gen > replay rate | grows with concurrency | **no effect** |
| S15 Anti-wraparound VACUUM | WAL volume (FREEZE+FPI) | hours at 1 TB scale | **no effect** |

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
