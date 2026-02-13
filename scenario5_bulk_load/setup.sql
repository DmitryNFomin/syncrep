-- Scenario 5: Bulk INSERT into heavily-indexed table (ETL scenario)
--
-- WHY THIS WORKS:
-- A bulk INSERT...SELECT of 1M rows generates WAL for:
--   - 1M heap inserts (~100 bytes each)
--   - 1M * 4 index inserts (~50-100 bytes each)
--   = ~500-600 MB of WAL in a single transaction
--
-- The primary writes this WAL sequentially (fast).
-- The standby must replay each row + all index inserts SERIALLY.
-- While replay is processing the bulk load WAL, any interleaved
-- probe transaction's COMMIT record is stuck behind the bulk WAL.
-- Under remote_apply, the probe waits. Under remote_write, it doesn't.
--
-- This simulates a real ETL pipeline, data import, or batch job
-- loading data into a table that has production indexes.

DROP TABLE IF EXISTS logs CASCADE;
DROP TABLE IF EXISTS probe_s5 CASCADE;

-- Target table WITH indexes already in place (production-like)
CREATE TABLE logs (
    id      bigserial PRIMARY KEY,
    ts      timestamptz NOT NULL,
    level   text        NOT NULL,
    service text        NOT NULL,
    message text        NOT NULL,
    trace_id text       NOT NULL
);

CREATE INDEX logs_ts         ON logs(ts);
CREATE INDEX logs_service_ts ON logs(service, ts);
CREATE INDEX logs_level_ts   ON logs(level, ts);
CREATE INDEX logs_trace      ON logs(trace_id);

-- Probe table
CREATE TABLE probe_s5 (
    id  serial PRIMARY KEY,
    val integer NOT NULL DEFAULT 0,
    ts  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO probe_s5 (val) SELECT generate_series(1, 10000);

ANALYZE;
CHECKPOINT;
