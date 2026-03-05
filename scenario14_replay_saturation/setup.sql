-- scenario14_replay_saturation/setup.sql
-- Table with many secondary indexes to generate heavy replay work per commit.
-- Each 50-row scattered UPDATE touches 10 indexes = 500+ distinct page
-- modifications per commit. At high concurrency, combined WAL generation
-- from multiple clients exceeds single-threaded replay throughput.

DROP TABLE IF EXISTS saturation_test;

CREATE TABLE saturation_test (
    id      int    PRIMARY KEY,
    val1    int    NOT NULL,
    val2    int    NOT NULL,
    val3    int    NOT NULL,
    val4    int    NOT NULL,
    val5    int    NOT NULL,
    status  smallint NOT NULL DEFAULT 0,
    filler  text   NOT NULL
);

-- 10 secondary indexes: each UPDATE row modifies all of them (non-HOT).
-- Mix of per-column and composite indexes for realistic replay cost.
CREATE INDEX sat_v1_idx     ON saturation_test (val1);
CREATE INDEX sat_v2_idx     ON saturation_test (val2);
CREATE INDEX sat_v3_idx     ON saturation_test (val3);
CREATE INDEX sat_v4_idx     ON saturation_test (val4);
CREATE INDEX sat_v5_idx     ON saturation_test (val5);
CREATE INDEX sat_status_idx ON saturation_test (status);
CREATE INDEX sat_v1v2_idx   ON saturation_test (val1, val2);
CREATE INDEX sat_v3v4_idx   ON saturation_test (val3, val4);
CREATE INDEX sat_v5s_idx    ON saturation_test (val5, status);
CREATE INDEX sat_filler_idx ON saturation_test (md5(filler));

INSERT INTO saturation_test (id, val1, val2, val3, val4, val5, status, filler)
SELECT
    i,
    (random() * 1000000)::int,
    (random() * 1000000)::int,
    (random() * 1000000)::int,
    (random() * 1000000)::int,
    (random() * 1000000)::int,
    (random() * 4)::smallint,
    repeat(chr(65 + (i % 26)), 200)
FROM generate_series(1, 500000) i;

ANALYZE saturation_test;
CHECKPOINT;
