-- Scenario 11: DROP TABLE of a large partitioned table — mass file unlink in commit replay
--
-- MECHANISM (xact.c:6236-6239, function xact_redo_commit()):
--   When a commit WAL record includes dropped relations (parsed->nrels > 0),
--   the startup process does TWO things before returning from the commit record:
--
--     1. XLogFlush(lsn) — synchronous WAL flush to advance minRecoveryPoint.
--        This forces a WAL write+fsync on the standby before the file is deleted,
--        implementing the WAL-before-truncation invariant.  This alone costs
--        several milliseconds.
--
--     2. DropRelationFiles(parsed->xlocators, parsed->nrels, true)
--        For each dropped relation, calls durable_unlink() on every fork:
--          main fork, FSM fork, VM fork, init fork (if init), TOAST heap,
--          TOAST index, TOAST FSM, TOAST VM.
--        Each durable_unlink() is a synchronous unlink(2) syscall.
--
--   For a partitioned table with 50 partitions, each having a primary key index
--   and a TOAST table, the DROP TABLE CASCADE commit record carries:
--
--     50 partitions × 3 forks (main, FSM, VM)          = 150 unlinks
--     50 pk indexes × 2 forks (main, FSM)               = 100 unlinks
--     50 TOAST heaps × 3 forks                          = 150 unlinks
--     50 TOAST pk indexes × 2 forks                     = 100 unlinks
--     ──────────────────────────────────────────────────────────────────
--     Total                                              ≈ 500 unlinks
--
--   Plus one XLogFlush at the start.  All inside the commit record replay,
--   all charged to any remote_apply waiter on the primary.
--
-- Under remote_write: DROP TABLE commits instantly after the primary finishes
--   (WAL was already streamed; only the commit WAL record needs to reach the
--   standby's page cache — a few KB).
--
-- Under remote_apply: the commit must wait for XLogFlush + ~500 unlinks.
--   On a filesystem with slow unlink() (e.g., ext4 with dir_index, btrfs,
--   or any busy I/O subsystem), each unlink may take 1-5ms.
--   500 unlinks × 2ms = 1 second of pure commit overhead.

DROP TABLE IF EXISTS part_test CASCADE;

-- Partitioned table: 50 partitions by hash of id.
-- Each partition gets its own heap storage (3 file forks).
CREATE TABLE part_test (
    id      bigint NOT NULL,
    val     text   NOT NULL,
    payload text,
    ts      timestamptz DEFAULT now(),
    PRIMARY KEY (id)          -- this creates a unique index on every partition
) PARTITION BY HASH (id);

-- Create 50 partitions.  Each inherits the primary key constraint, producing
-- a separate index file per partition.  Also adds a TOAST table per partition
-- (because of the text columns).
DO $$
BEGIN
    FOR i IN 0..49 LOOP
        EXECUTE format(
            'CREATE TABLE part_test_%s
             PARTITION OF part_test
             FOR VALUES WITH (MODULUS 50, REMAINDER %s)',
            i, i);
    END LOOP;
END;$$;

-- Insert enough rows that the table and its TOAST are real (prevents empty-file
-- optimization from hiding the unlink cost), but keep setup fast.
INSERT INTO part_test (id, val, payload)
SELECT
    i,
    md5(i::text),
    repeat(md5(i::text), 8)   -- ~256 bytes → forces TOAST
FROM generate_series(1, 200000) i;

ANALYZE part_test;
CHECKPOINT;
