-- scenario15_antiwrap_vacuum/setup.sql
-- Table sized to produce visible VACUUM FREEZE WAL volume (~700 MB on-disk).
-- 2M rows × ~350 bytes each (id bigint + md5 payload + 300-char filler).
-- A preceding CHECKPOINT makes every page dirty for the next write,
-- causing VACUUM FREEZE to emit a full-page image (8 KB) per page —
-- amplifying WAL to match the on-disk table size.

CREATE TABLE IF NOT EXISTS antiwrap_test (
    id      bigint PRIMARY KEY,
    payload text   NOT NULL,
    filler  text   NOT NULL
);

TRUNCATE antiwrap_test;

INSERT INTO antiwrap_test (id, payload, filler)
SELECT
    i,
    md5(i::text),
    repeat('x', 300)
FROM generate_series(1, 2000000) i;

ANALYZE antiwrap_test;
