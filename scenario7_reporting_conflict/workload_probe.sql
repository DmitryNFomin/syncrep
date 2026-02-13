-- Probe workload: lightweight UPDATE to measure commit latency.
\set id random(1, 10000)
UPDATE probe_s7 SET val = val + 1, ts = now() WHERE id = :id;
