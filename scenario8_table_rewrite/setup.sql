-- Scenario 8: Table rewrite (VACUUM FULL / CLUSTER) during live traffic
--
-- WHY THIS WORKS:
-- VACUUM FULL rewrites the entire table + all indexes into WAL.
-- 500K live rows × ~500 bytes each = ~250 MB of heap, plus ~80 MB of
-- rebuilt indexes = ~330 MB of WAL from the rewrite.
--
-- The standby must replay all of it serially. Under remote_apply,
-- concurrent OLTP commits wait for replay to advance past the rewrite WAL.

DROP TABLE IF EXISTS bloated CASCADE;
DROP TABLE IF EXISTS probe_s8 CASCADE;

CREATE TABLE bloated (
    id         integer      PRIMARY KEY,
    status     text         NOT NULL,
    data       text         NOT NULL,
    extra      text         NOT NULL,
    updated_at timestamptz  NOT NULL DEFAULT now()
);

-- 3M rows × ~500 bytes each → ~1.5 GB table (before bloat)
INSERT INTO bloated
SELECT i,
    (ARRAY['active','pending','done','archived'])[1+(random()*3)::int],
    repeat(md5(random()::text), 10),       -- ~320 bytes
    repeat(md5(random()::text), 5),        -- ~160 bytes
    now() - make_interval(days => (random() * 30)::int)
FROM generate_series(1, 3000000) i;

CREATE INDEX bloated_status  ON bloated(status);
CREATE INDEX bloated_updated ON bloated(updated_at);
CREATE INDEX bloated_data_prefix ON bloated(left(data, 32));

-- Delete 50% to create table bloat
DELETE FROM bloated WHERE id % 2 = 0;

-- Probe table
CREATE TABLE probe_s8 (
    id  serial PRIMARY KEY,
    val integer NOT NULL DEFAULT 0,
    ts  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO probe_s8 (val) SELECT generate_series(1, 10000);

ANALYZE;
CHECKPOINT;
