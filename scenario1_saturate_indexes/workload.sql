-- pgbench custom script: scattered batch UPDATE on the heavily-indexed table.
--
-- Each execution updates 50 rows SCATTERED across the full 2M-row table.
-- Unlike contiguous BETWEEN range (which shares 2-3 heap pages), scattered
-- rows each land on a DIFFERENT heap page and different index leaf pages.
--
-- 50 scattered rows × 15 indexes = 750 distinct index page modifications.
-- Plus ~50 distinct heap page modifications. Total: ~800 page writes.
-- Each page write during replay requires a buffer lookup + apply.
-- Replay must process all 800 page modifications serially.
--
-- Contiguous range: 25 rows share 3 pages → ~45 page mods → ~0.2ms replay
-- Scattered random:  50 rows on 50 pages → ~800 page mods → ~10-15ms replay

\set seed random(1, 40000)

UPDATE idx_heavy
   SET val1   = (random() * 1000000)::int,
       val2   = (random() * 1000000)::int,
       val3   = (random() * 1000000)::int,
       val4   = (random() * 1000000)::int,
       val5   = (random() * 1000000)::int,
       val6   = (random() * 1000000)::int,
       status = (random() * 4)::smallint
 WHERE id IN (
    SELECT :seed + (i - 1) * 40000
    FROM generate_series(1, 50) i
 );
