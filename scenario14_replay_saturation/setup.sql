-- scenario14_replay_saturation/setup.sql
-- Wide-row table with secondary indexes to generate meaningful replay work.
-- Each 5-row UPDATE touches 4 indexes = 20 index modifications per commit.
-- At high concurrency, WAL generation outpaces single-threaded replay.

DROP TABLE IF EXISTS saturation_test;

CREATE TABLE saturation_test (
    id      int    PRIMARY KEY,
    val1    text   NOT NULL,
    val2    text   NOT NULL,
    counter bigint NOT NULL DEFAULT 0
);

-- Secondary indexes: each UPDATE must modify these during replay
CREATE INDEX sat_val1_idx    ON saturation_test (md5(val1));
CREATE INDEX sat_val2_idx    ON saturation_test (md5(val2));
CREATE INDEX sat_counter_idx ON saturation_test (counter);

INSERT INTO saturation_test (id, val1, val2)
SELECT
    i,
    repeat(chr(65 + (i % 26)), 250),
    repeat(chr(65 + ((i + 7) % 26)), 250)
FROM generate_series(1, 100000) i
ON CONFLICT DO NOTHING;

ANALYZE saturation_test;
CHECKPOINT;
