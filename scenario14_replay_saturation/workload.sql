-- scenario14_replay_saturation/workload.sql
-- Write-heavy single-row UPDATE.  Both text columns are mutated so the
-- full row is written to WAL on every transaction (~3-5 KB of WAL/txn
-- including heap page + index page + possible FPI).

UPDATE saturation_test
SET    counter = counter + 1,
       val1    = md5(id::text || val1),
       val2    = md5(val2 || id::text)
WHERE  id = (random() * 99999 + 1)::int;
