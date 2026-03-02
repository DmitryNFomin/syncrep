-- Scenario 13: Hash index VACUUM — dual snapshot conflict + buffer cleanup lock
--
-- MECHANISM (hash_xlog.c:991-1082, function hash_xlog_vacuum_one_page()):
--   Hash index VACUUM generates XLOG_HASH_VACUUM_ONE_PAGE records for each
--   bucket page that contains dead index entries.  During replay, the startup
--   process calls TWO separate conflict resolution mechanisms in sequence:
--
--   Step 1 — Snapshot conflict (hash_xlog.c:1024-1029):
--     ResolveRecoveryConflictWithSnapshot(xldata->snapshotConflictHorizon, ...)
--     This cancels or waits for standby sessions whose snapshots are older than
--     the horizon — the same mechanism as scenarios 2, 7.
--
--   Step 2 — Buffer cleanup lock (hash_xlog.c:1055):
--     XLogReadBufferForRedoExtended(record, 0, RBM_NORMAL, true, &buffer)
--     The `true` is `get_cleanup_lock`: calls LockBufferForCleanup() on the
--     bucket page.  This waits until ALL pins on the page drop to zero.
--
--   No other WAL record type in PostgreSQL combines both mechanisms in sequence.
--   Scenarios 2/7/8 use only the snapshot conflict; scenario 9 uses only buffer
--   pins.  S13 requires the standby to have BOTH an active snapshot AND
--   concurrent pins on the hash bucket pages.
--
-- Setup:
--   Table with a HASH index.  We insert many rows (which triggers bucket splits
--   via XLOG_HASH_SPLIT_ALLOCATE_PAGE, which also takes cleanup locks on both
--   old and new buckets), then delete half to create dead index entries, then
--   run VACUUM to generate XLOG_HASH_VACUUM_ONE_PAGE WAL.
--
-- Standby blocker (standby_blocker.sql):
--   REPEATABLE READ transaction that scans the hash index.  This provides BOTH:
--   (a) a long-lived snapshot (triggers Step 1 conflict)
--   (b) brief buffer pins on bucket pages during the scan (triggers Step 2)

DROP TABLE IF EXISTS hash_test CASCADE;
DROP TABLE IF EXISTS probe_s13;

-- Hash index is specified explicitly; PostgreSQL defaults to btree.
CREATE TABLE hash_test (
    id    bigint NOT NULL,
    val   text   NOT NULL
);

-- Hash index on id — this is what generates all the hash-specific WAL records.
CREATE INDEX hash_test_hash_idx ON hash_test USING hash (id);

-- Insert enough rows to create multiple hash buckets (and thus potential for
-- VACUUM generating per-bucket cleanup records).
-- Hash indexes start with 2 buckets and double when load factor > 2.
-- At ~500 bytes/row and 2× load: ~50K rows gives 4-8 bucket pages.
INSERT INTO hash_test (id, val)
SELECT i, md5(i::text)
FROM generate_series(1, 200000) i;

-- Delete half the rows: these become dead index entries that VACUUM must
-- remove with XLOG_HASH_VACUUM_ONE_PAGE records.
DELETE FROM hash_test WHERE id % 2 = 0;

-- Probe table for measuring commit latency (unrelated to hash_test).
CREATE TABLE probe_s13 (
    id  bigserial PRIMARY KEY,
    val int
);

ANALYZE hash_test;
ANALYZE probe_s13;
CHECKPOINT;
