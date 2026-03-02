-- pgbench script for STANDBY: continuous full-table sequential scan.
--
-- Each execution reads all ~6800 pages of freeze_test, briefly pinning each
-- buffer as it reads the tuples on that page.  Run many parallel copies
-- (-c 20 in run.sh) to create sustained aggregate pin pressure across the
-- entire table.
--
-- The goal: at any moment during VACUUM FREEZE WAL replay, there is a
-- meaningful probability that the page the startup process wants to freeze
-- is currently pinned by one of these scans.

SELECT count(*) FROM freeze_test;
