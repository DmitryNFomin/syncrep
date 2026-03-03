-- scenario14_replay_saturation/setup.sql
-- Wide-row table to generate meaningful WAL per UPDATE (~3-5 KB per txn).
-- 100K rows keeps setup fast while giving enough breadth for concurrency tests.

CREATE TABLE IF NOT EXISTS saturation_test (
    id      int    PRIMARY KEY,
    val1    text   NOT NULL,
    val2    text   NOT NULL,
    counter bigint NOT NULL DEFAULT 0
);

INSERT INTO saturation_test (id, val1, val2)
SELECT
    i,
    repeat(chr(65 + (i % 26)), 250),
    repeat(chr(65 + ((i + 7) % 26)), 250)
FROM generate_series(1, 100000) i
ON CONFLICT DO NOTHING;
