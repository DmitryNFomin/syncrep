-- Scenario 6: Full Page Image (FPI) storm after frequent checkpoints
--
-- WHY THIS WORKS:
-- After each checkpoint, the FIRST modification to any heap or index page
-- writes a Full Page Image (8 KB) into WAL instead of a small delta (~100-200 B).
-- This is PostgreSQL's torn-page protection (full_page_writes = on by default).
--
-- With checkpoint_timeout = 15s and random scattered UPDATEs across a large
-- table, most pages are "cold" (unmodified since the last checkpoint) when
-- touched. Each UPDATE generates:
--   - 8 KB heap FPI (instead of ~200 B delta)
--   - 8 KB index FPI per touched index page
--   = 16-24 KB of WAL per UPDATE instead of ~400 B
--   = 40-60x WAL amplification
--
-- The standby must apply all those 8 KB page images. With 48 MB
-- shared_buffers, constant buffer eviction + disk writes slow replay.
-- fillfactor=50 doubles the page count, spreading rows even thinner.

DROP TABLE IF EXISTS wide_table CASCADE;

CREATE TABLE wide_table (
    id       integer PRIMARY KEY,
    counter  integer NOT NULL DEFAULT 0,
    padding1 text    NOT NULL,
    padding2 text    NOT NULL
) WITH (fillfactor = 50);

-- Each row: ~450 bytes → with fillfactor=50, ~9 rows per 8KB page
-- 2M rows → ~220K pages → ~1.7 GB heap
INSERT INTO wide_table (id, counter, padding1, padding2)
SELECT i, 0,
    repeat(chr(65 + (i % 26)), 200),
    repeat(chr(97 + (i % 26)), 200)
FROM generate_series(1, 2000000) i;

-- Index generates additional FPIs when updated
CREATE INDEX wide_counter_idx ON wide_table(counter);

ANALYZE wide_table;
CHECKPOINT;
