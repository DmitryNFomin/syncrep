-- Probe workload: lightweight INSERT to measure commit latency.
-- Under remote_apply, this commit must wait for all preceding WAL
-- (including VACUUM FREEZE records) to be replayed on the standby.
INSERT INTO probe_s15 (val) VALUES (1);
