-- pgbench script for PRIMARY: simple probe INSERT.
--
-- Under remote_apply this commit must wait for all preceding WAL in the
-- replication stream (including VACUUM FREEZE records) to be fully applied
-- on the standby before the primary returns success.
--
-- Under remote_write it only waits for the WAL to reach the standby's
-- OS page cache, which is nearly instant.

INSERT INTO probe_s9 (val) VALUES (1);
