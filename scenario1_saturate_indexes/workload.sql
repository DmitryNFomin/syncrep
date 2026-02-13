-- pgbench custom script: random UPDATE on the heavily-indexed table.
--
-- Each execution updates ONE row but modifies 6 indexed columns → the startup
-- process must update heap + 10 index entries (every secondary index whose
-- key column changed, plus the composites). With random keys the touched index
-- pages are scattered, causing random I/O on replay.

\set id random(1, 2000000)
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
 WHERE id = :id;
