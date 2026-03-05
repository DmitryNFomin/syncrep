-- pgbench script for STANDBY: full-table sequential scan.
--
-- Each execution reads all ~20 pages of freeze_test, briefly pinning each
-- buffer as it reads and processes the tuples on that page.
--
-- Run 80 parallel copies on ~20 pages: 4 expected pins per page.
-- Zero-pin windows are too brief (~0.5μs) for the startup process to wake
-- (~5μs) and acquire LockBufferForCleanup. Result: true livelock.

SELECT sum(length(a) + length(b) + length(c)) FROM freeze_test;
