-- pgbench script for STANDBY: full-table sequential scan with per-row sleep.
--
-- pg_sleep(0.001) is evaluated in the WHERE clause for each row.
-- During pg_sleep, the backend sleeps but KEEPS the buffer pin on the
-- current page. With 5 rows/page × 1ms sleep = 5ms pin per page.
--
-- 80 scanners on ~20 pages with 5ms pins: the pgbench protocol overhead
-- (~200μs between queries) becomes negligible, giving ~97% duty cycle.
-- Effective concurrent pins per page ≈ 4 → true livelock.

SELECT sum(length(a) + length(b) + length(c))
FROM freeze_test
WHERE pg_sleep(0.001) IS NOT NULL;
