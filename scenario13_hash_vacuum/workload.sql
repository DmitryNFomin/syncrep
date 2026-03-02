-- Primary probe: simple INSERT to measure commit latency.
-- Under remote_apply, this commit waits for all preceding WAL
-- (including XLOG_HASH_VACUUM_ONE_PAGE records with their dual conflict
-- resolution) to be replayed on the standby.
INSERT INTO probe_s13 (val) VALUES (1);
