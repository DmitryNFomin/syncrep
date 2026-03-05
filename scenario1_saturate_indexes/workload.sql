-- pgbench custom script: scattered batch UPDATE on the heavily-indexed table.
--
-- Each execution updates 100 rows SCATTERED across the full 2M-row table.
-- Rows are spaced 20,000 apart — each lands on a different heap page and
-- different index leaf pages.
--
-- 100 scattered rows × 15 indexes ≈ 1500 distinct index page modifications.
-- Plus ~100 distinct heap page modifications. Total: ~1600 page writes.
-- Each page write during replay requires a buffer lookup + apply.
-- Replay must process all 1600 page modifications serially.
--
-- With 32 clients generating these concurrently, WAL generation rate
-- overwhelms single-threaded replay → backlog builds → added latency grows.

\set seed random(1, 20000)

UPDATE idx_heavy
   SET val1   = (random() * 1000000)::int,
       val2   = (random() * 1000000)::int,
       val3   = (random() * 1000000)::int,
       val4   = (random() * 1000000)::int,
       val5   = (random() * 1000000)::int,
       val6   = (random() * 1000000)::int,
       status = (random() * 4)::smallint
 WHERE id IN (
    SELECT :seed + (i - 1) * 20000
    FROM generate_series(1, 100) i
 );
