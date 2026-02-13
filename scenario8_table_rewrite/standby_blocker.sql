-- S8 standby blocker: hold AccessShareLock on bloated table.
-- When VACUUM FULL acquires AccessExclusiveLock, the WAL record
-- conflicts with this lock → replay blocks until this transaction ends.
-- (Different from S7: lock conflict vs snapshot/prune conflict.)
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM bloated;
SELECT pg_sleep(60);
COMMIT;
