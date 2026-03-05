-- scenario14_replay_saturation/workload.sql
-- 50-row scattered UPDATE with 10 secondary indexes (+ PK).
-- Rows are spaced 10,000 apart across the 500K-row table, so each row
-- lands on a different heap page and different index leaf pages.
--
-- 50 scattered rows × 11 indexes = ~550 distinct page modifications per
-- commit. Each page modification during replay requires a buffer lookup +
-- lock + apply. All processed serially through one startup process.
--
-- WAL per commit: ~250-350 KB (550 page mods × ~0.5 KB avg).
--
-- At low concurrency, replay keeps up → minimal added latency.
-- At high concurrency, combined WAL rate from all clients approaches
-- single-threaded replay throughput → commits queue → added_ms grows.

\set seed random(1, 10000)

UPDATE saturation_test
SET    val1   = (random() * 1000000)::int,
       val2   = (random() * 1000000)::int,
       val3   = (random() * 1000000)::int,
       val4   = (random() * 1000000)::int,
       val5   = (random() * 1000000)::int,
       status = (random() * 4)::smallint
WHERE  id IN (
    SELECT :seed + (i - 1) * 10000
    FROM generate_series(1, 50) i
);
