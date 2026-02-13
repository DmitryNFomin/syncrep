-- Probe table for scenario 7 (orders table comes from S2 setup)
DROP TABLE IF EXISTS probe_s7 CASCADE;

CREATE TABLE probe_s7 (
    id  serial PRIMARY KEY,
    val integer NOT NULL DEFAULT 0,
    ts  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO probe_s7 (val) SELECT generate_series(1, 10000);

ANALYZE probe_s7;
