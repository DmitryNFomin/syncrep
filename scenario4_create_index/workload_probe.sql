-- Probe workload: lightweight UPDATE to measure commit latency.
-- Any extra latency comes from waiting for standby replay (remote_apply).
\set id random(1, 10000)
UPDATE probe_s4 SET val = val + 1, ts = now() WHERE id = :id;
