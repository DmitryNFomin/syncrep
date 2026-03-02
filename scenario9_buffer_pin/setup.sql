-- Scenario 9: Buffer pin contention during VACUUM FREEZE replay
--
-- MECHANISM:
-- When the standby startup process replays XLOG_HEAP2_FREEZE_PAGE WAL records
-- it calls ResolveRecoveryConflictWithBufferPin(buf) for the target buffer.
-- This function tries to acquire a BufferCleanupLock (LockBufferForCleanup),
-- which requires that no other backend holds a pin on that buffer.
--
-- With max_standby_streaming_delay = -1, the startup process waits indefinitely
-- for all pins to clear before it can apply the freeze record and advance.
--
-- Concurrent full-table scans on the standby hold a pin on each page briefly
-- (for the duration of reading that page's tuples — typically microseconds).
-- With many parallel scans running continuously, there is a non-zero probability
-- that ANY given page has a pin at the moment the startup process requests it.
-- Each such collision costs up to one scan iteration worth of wait time.
--
-- The effect is amplified by running a CHECKPOINT before VACUUM FREEZE:
-- PostgreSQL's full_page_writes means the first modification to each page after
-- a checkpoint generates an 8 KB Full Page Image (FPI) in WAL instead of a
-- small delta. VACUUM FREEZE touches every page → a CHECKPOINT just before it
-- inflates the WAL to ~8 KB per page, making the replay pipeline much longer.
--
-- Result: many small per-page stalls aggregate to seconds of total replay delay,
-- all charged to remote_apply commits on the primary.
--
-- Comparison with scenarios 2/7 (snapshot conflicts):
--   S2/S7: one long-lived snapshot blocks ALL replay for 60-90 seconds at once.
--   S9:    no long-lived snapshot needed; stalls are per-page (microseconds to
--          milliseconds each) but numerous, adding up to seconds of total wait.

DROP TABLE IF EXISTS freeze_test;
DROP TABLE IF EXISTS probe_s9;

-- Table sized to generate meaningful WAL volume:
-- ~180 bytes/row → ~44 rows/8KB page → 300K rows ≈ 6800 pages ≈ 53 MB heap.
-- CHECKPOINT + VACUUM FREEZE generates ~6800 × 8 KB = ~53 MB of FPI WAL.
-- autovacuum_enabled=false: prevents autovacuum from preempting our manual FREEZE.
CREATE TABLE freeze_test (
    id   bigint,
    a    text,        -- 32-char md5
    b    text,        -- 32-char md5 (updated between freeze cycles to unfreeze)
    ts   timestamptz DEFAULT now()
) WITH (autovacuum_enabled = false);

INSERT INTO freeze_test
SELECT i, md5(i::text), md5((i * 3)::text), now()
FROM generate_series(1, 300000) i;

-- Probe table on which we measure commit latency.
-- This is deliberately a different table from freeze_test: the buffer pin
-- stall affects the entire replay stream, not just the frozen table.
CREATE TABLE probe_s9 (
    id  bigserial PRIMARY KEY,
    val int);

ANALYZE freeze_test;
ANALYZE probe_s9;

-- CHECKPOINT so the next VACUUM FREEZE generates FPIs for every page.
CHECKPOINT;
