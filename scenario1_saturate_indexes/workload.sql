-- pgbench custom script: batch UPDATE on the heavily-indexed table.
--
-- Each execution updates 25 rows, modifying 6 indexed columns per row.
-- With 15 secondary indexes, this generates ~375 index modifications per
-- commit (25 rows × 15 indexes). The primary executes this in parallel
-- across backends; the standby replays ALL 375 index updates serially
-- through the single startup process.
--
-- 375 index mods × ~27μs each ≈ 10ms of replay overhead per commit.

\set start random(1, 1999975)
\set v1 random(1, 1000000)
\set v2 random(1, 1000000)
\set v3 random(1, 1000000)
\set v4 random(1, 1000000)
\set v5 random(1, 1000000)
\set v6 random(1, 1000000)
\set st random(0, 4)

UPDATE idx_heavy
   SET val1   = :v1,
       val2   = :v2,
       val3   = :v3,
       val4   = :v4,
       val5   = :v5,
       val6   = :v6,
       status = :st
 WHERE id BETWEEN :start AND :start + 24;
