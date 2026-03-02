-- Run on STANDBY: holds a REPEATABLE READ snapshot AND pins hash bucket pages.
--
-- This provides both ingredients for the dual conflict in XLOG_HASH_VACUUM_ONE_PAGE:
--   1. A snapshot older than the deleted tuples' XIDs → triggers Step 1
--      (ResolveRecoveryConflictWithSnapshot)
--   2. Active reads of hash bucket pages → brief pins → triggers Step 2
--      (LockBufferForCleanup waits for pins to clear)
--
-- The 90-second pg_sleep keeps the snapshot alive long enough for the scenario
-- runner to generate hash VACUUM WAL and observe the stall.

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- Touch hash_test to fix the snapshot at a point where dead tuples were visible.
SELECT count(*) FROM hash_test;

-- Hold the snapshot open while probe pgbench runs on the primary.
SELECT pg_sleep(90);

-- Re-scan to keep pin pressure on bucket pages during the sleep window.
-- (The sleep above holds the snapshot; the scan below, if done periodically,
-- would increase bucket page pin rate — here one post-sleep scan suffices.)
SELECT count(*) FROM hash_test WHERE id % 7 = 0;

COMMIT;
