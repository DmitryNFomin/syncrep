-- Scenario 4: Schema migration on a large table
--
-- WHY THIS WORKS:
-- A realistic migration: UPDATE 2M rows + CREATE INDEX generates ~2GB of WAL.
-- The UPDATE rewrites every row (new tuple + WAL record per row), creating a
-- massive WAL burst. The standby replays it serially — single-threaded startup.
-- While the standby is processing the migration WAL, remote_apply commits to
-- OTHER tables stall. remote_write commits are unaffected.

DROP TABLE IF EXISTS events CASCADE;
DROP TABLE IF EXISTS probe_s4 CASCADE;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 2M rows, ~200 bytes per row → ~400 MB heap
-- Secondary indexes at setup → UPDATE during migration must update all of them,
-- generating ~6 WAL records per row (heap + 5 indexes) = 12M replay operations.
CREATE TABLE events (
    id          bigserial PRIMARY KEY,
    ts          timestamptz NOT NULL,
    user_id     integer     NOT NULL,
    service     text        NOT NULL,
    duration_ms integer     NOT NULL,
    payload     text        NOT NULL
);

INSERT INTO events (ts, user_id, service, duration_ms, payload)
SELECT
    now() - make_interval(days => (random() * 365)::int),
    (random() * 10000)::int,
    (ARRAY['auth','billing','search','export','notify'])[1+(random()*4)::int],
    (random() * 5000)::int,
    md5(random()::text) || '-' || md5(random()::text) || '-' || md5(random()::text)
FROM generate_series(1, 2000000);

-- Secondary indexes: force non-HOT updates during migration.
-- The migration UPDATE changes user_id and duration_ms, which forces
-- index entry updates on ALL indexes (non-HOT is all-or-nothing).
CREATE INDEX events_user_ts   ON events(user_id, ts);
CREATE INDEX events_dur       ON events(duration_ms);
CREATE INDEX events_svc_ts    ON events(service, ts);
CREATE INDEX events_user_dur  ON events(user_id, duration_ms);

-- Probe table: tiny, simple — measures raw commit latency
CREATE TABLE probe_s4 (
    id  serial PRIMARY KEY,
    val integer NOT NULL DEFAULT 0,
    ts  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO probe_s4 (val) SELECT generate_series(1, 10000);

ANALYZE events;
ANALYZE probe_s4;
CHECKPOINT;
