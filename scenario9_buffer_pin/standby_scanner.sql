-- pgbench script for STANDBY: expensive full-table sequential scan.
--
-- Each execution reads all ~1000 pages of freeze_test, briefly pinning each
-- buffer as it reads and processes the tuples on that page.
--
-- The expensive per-row computation (length(a) + length(b) + length(c))
-- forces the backend to decompress/access the full inline text data for each
-- row, extending the pin hold time per page to ~200μs instead of ~10μs.
--
-- Run 80 parallel copies to create sustained pin pressure: at any moment,
-- P ≈ scanners × pin_duration / scan_cycle_time ≈ 80 × 200μs / 100ms ≈ 16%.
-- This means ~160 of the ~1000 pages will have a pin collision during
-- VACUUM FREEZE replay, each costing one scan cycle of wait time.

SELECT sum(length(a) + length(b) + length(c)) FROM freeze_test;
