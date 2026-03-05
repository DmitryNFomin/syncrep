-- scenario14_replay_saturation/workload.sql
-- 5-row batch UPDATE with wide rows and 4 indexes (PK + 3 secondary).
-- Each commit: 5 rows × 4 indexes = 20 index modifications + 5 heap updates.
-- WAL per commit: ~15-25 KB (heap pages + index pages + possible FPI).
--
-- At low concurrency, replay keeps up → minimal added latency.
-- At high concurrency, WAL generation rate exceeds single-threaded replay
-- throughput → commits queue behind the startup process → added latency
-- grows with concurrency.

\set start random(1, 99995)

UPDATE saturation_test
SET    counter = counter + 1,
       val1    = md5(id::text || val1),
       val2    = md5(val2 || id::text)
WHERE  id BETWEEN :start AND :start + 4;
