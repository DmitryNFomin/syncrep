-- Run on PRIMARY to monitor the write/apply delta.
-- The key column is "apply_delta": time between WAL arriving on standby
-- and actually being replayed. Under remote_write this is invisible to
-- the committing backend; under remote_apply it IS the extra latency.

SELECT
    now()                                   AS ts,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    sent_lsn  - replay_lsn                 AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag,
    replay_lag - write_lag                  AS apply_delta
FROM pg_stat_replication;
