-- pgbench script for STANDBY: full-table sequential scan.
--
-- Each execution reads all ~1000 pages of freeze_test, briefly pinning each
-- buffer as it reads and processes the tuples on that page.
--
-- Run 80 parallel copies: on beefy HW, this creates a pin livelock for
-- VACUUM FREEZE replay. LockBufferForCleanup() needs pin_count=1, but
-- scanners cycle so fast that every page always has at least one pinner.
-- Result: replay is completely blocked for the scan duration.

SELECT sum(length(a) + length(b) + length(c)) FROM freeze_test;
