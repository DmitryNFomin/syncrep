-- scenario15_antiwrap_vacuum/setup.sql
-- Large table to produce significant VACUUM FREEZE WAL volume.
-- 5M rows × ~400 bytes each ≈ 2 GB on-disk → ~250K pages.
-- A preceding CHECKPOINT makes every page dirty for the next write,
-- causing VACUUM FREEZE to emit a full-page image (8 KB) per page.
--
-- A probe table (separate from antiwrap_test) measures commit latency
-- during the VACUUM FREEZE — any replay stall is visible there.

DROP TABLE IF EXISTS antiwrap_test;
DROP TABLE IF EXISTS probe_s15;

CREATE TABLE antiwrap_test (
    id      bigint PRIMARY KEY,
    payload text   NOT NULL,
    filler  text   NOT NULL
) WITH (autovacuum_enabled = false);

INSERT INTO antiwrap_test (id, payload, filler)
SELECT
    i,
    md5(i::text),
    repeat('x', 300)
FROM generate_series(1, 5000000) i;

-- Probe table: tiny, measures raw commit latency.
CREATE TABLE probe_s15 (
    id  bigserial PRIMARY KEY,
    val int NOT NULL DEFAULT 0
);

ANALYZE antiwrap_test;
ANALYZE probe_s15;
