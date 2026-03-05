-- pgbench script for STANDBY: expensive full-table sequential scan.
--
-- Each execution reads all ~1000 pages of freeze_test, briefly pinning each
-- buffer as it reads and processes the tuples on that page.
--
-- The expensive per-row computation (length(a) + length(b) + length(c))
-- forces the backend to decompress/access the full inline text data for each
-- row, extending the pin hold time per page to ~200μs instead of ~10μs.
--
-- Run 20 parallel copies to create sustained pin pressure. On beefy HW,
-- scan cycle ≈ 20ms → P ≈ 20 × 200μs / 20ms ≈ 20%.
-- ~200 of ~1000 pages will collide during VACUUM FREEZE replay.
-- (80 scanners caused 100% collision = complete replay stall on fast HW.)

SELECT sum(length(a) + length(b) + length(c)) FROM freeze_test;
