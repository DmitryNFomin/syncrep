-- Scenario 12: VACUUM FULL + active logical slot — pg_fsync() per rewrite record
--
-- PREREQUISITE: wal_level = logical  (requires server restart if not already set)
--
-- MECHANISM (rewriteheap.c:1132, function heap_xlog_logical_rewrite()):
--   When wal_level = logical AND at least one logical replication slot exists,
--   CLUSTER and VACUUM FULL write XLOG_HEAP2_REWRITE WAL records so that logical
--   decoding can track old-TID → new-TID mappings through a table rewrite.
--
--   Each XLOG_HEAP2_REWRITE record represents a batch of remapped tuples.
--   During standby replay, heap_xlog_logical_rewrite() is called for every record
--   and does:
--     1. Opens or creates a transient mapping file
--     2. ftruncate() to the write position
--     3. pg_pwrite() with the new mapping data
--     4. pg_fsync(fd)  ← synchronous fdatasync on every record, not just the last
--
--   The number of XLOG_HEAP2_REWRITE records depends on the rewrite batch size
--   (LOGICAL_HEAP_REWRITE_FLUSH_FREQUENCY in rewriteheap.h, currently 1000
--   tuples per batch).  For a 300K-row table: ~300 records → ~300 fsyncs.
--
--   On a datacenter-grade SSD, 300 fsyncs ≈ 300 × 1-5ms = 300-1500ms of extra
--   commit latency under remote_apply (invisible to remote_write).
--
-- Without a logical slot: XLOG_HEAP2_REWRITE records are never written.
--   VACUUM FULL commits instantly under both modes (just heap/index rewrites).
-- With a logical slot: ~300 fsyncs add to the replay cost of the commit.

-- Check that wal_level is logical before proceeding
DO $$
BEGIN
    IF current_setting('wal_level') <> 'logical' THEN
        RAISE EXCEPTION
            'Scenario 12 requires wal_level = logical (current: %)',
            current_setting('wal_level');
    END IF;
END;$$;

DROP TABLE IF EXISTS rewrite_test;

-- Drop the slot if it already exists (idempotent setup)
DO $$
BEGIN
    PERFORM pg_drop_replication_slot('syncrep_bench_slot')
    FROM pg_replication_slots
    WHERE slot_name = 'syncrep_bench_slot';
EXCEPTION WHEN OTHERS THEN
    NULL;
END;$$;

-- Create a logical replication slot.  This is the trigger: without an active
-- slot, no XLOG_HEAP2_REWRITE records are written even with wal_level=logical.
SELECT pg_create_logical_replication_slot('syncrep_bench_slot', 'pgoutput');

-- Table: 300K rows, ~350 bytes each including TOAST ≈ 100 MB heap.
-- After UPDATE-all-rows bloat, VACUUM FULL rewrites it from ~200 MB to ~100 MB.
-- At 1000 tuples/batch: ~300 XLOG_HEAP2_REWRITE records → ~300 fsyncs during replay.
CREATE TABLE rewrite_test (
    id   bigint PRIMARY KEY,
    val  text NOT NULL,       -- md5: 32 chars, will be updated to create bloat
    pad  text NOT NULL        -- padding to inflate row size
) WITH (autovacuum_enabled = false);

INSERT INTO rewrite_test (id, val, pad)
SELECT i, md5(i::text), repeat(md5(i::text), 3)
FROM generate_series(1, 300000) i;

ANALYZE rewrite_test;
CHECKPOINT;
