-- Scenario 1: Saturate the single-threaded apply process
--
-- WHY THIS WORKS:
-- An UPDATE touching a row in a table with N indexes generates ~(1 + N) WAL
-- records: one heap update + one index entry change per index. On the primary
-- these are generated in parallel across backends. On the standby the startup
-- process replays them serially, doing random I/O into each index's pages.
--
-- With 15 secondary indexes and fillfactor=50 (doubling the page count),
-- the working set is ~3-4 GB — far beyond the standby's 48 MB shared_buffers.
-- Every replayed index entry is a random I/O cache miss.

DROP TABLE IF EXISTS idx_heavy;

-- fillfactor=50: only fill each heap page to 50%.
-- This doubles the number of heap pages (more random I/O on replay)
-- and spreads rows across more pages so fewer fit in the standby's tiny cache.
CREATE TABLE idx_heavy (
    id      integer PRIMARY KEY,
    acct_id integer NOT NULL,
    val1    integer NOT NULL,
    val2    integer NOT NULL,
    val3    integer NOT NULL,
    val4    integer NOT NULL,
    val5    integer NOT NULL,
    val6    integer NOT NULL,
    status  smallint NOT NULL DEFAULT 0,
    payload text    NOT NULL DEFAULT ''
) WITH (fillfactor = 50);

-- 15 secondary indexes: each UPDATE that changes these columns must
-- insert new index entries into every one of them during replay.
--
-- Per-column indexes (8)
CREATE INDEX idx_heavy_acct    ON idx_heavy (acct_id);
CREATE INDEX idx_heavy_val1    ON idx_heavy (val1);
CREATE INDEX idx_heavy_val2    ON idx_heavy (val2);
CREATE INDEX idx_heavy_val3    ON idx_heavy (val3);
CREATE INDEX idx_heavy_val4    ON idx_heavy (val4);
CREATE INDEX idx_heavy_val5    ON idx_heavy (val5);
CREATE INDEX idx_heavy_val6    ON idx_heavy (val6);
CREATE INDEX idx_heavy_status  ON idx_heavy (status);

-- Composite indexes (4) — wide keys mean larger btree entries, more page splits
CREATE INDEX idx_heavy_comp1   ON idx_heavy (acct_id, status, val1);
CREATE INDEX idx_heavy_comp2   ON idx_heavy (status, val4, val5);
CREATE INDEX idx_heavy_comp3   ON idx_heavy (val1, val2, val3, val4);
CREATE INDEX idx_heavy_comp4   ON idx_heavy (val5, val6, status, acct_id);

-- Functional indexes (3) — replay must recompute the expression for each row
CREATE INDEX idx_heavy_func1   ON idx_heavy (abs(val1 - val2));
CREATE INDEX idx_heavy_func2   ON idx_heavy ((val3 + val4 + val5));
CREATE INDEX idx_heavy_func3   ON idx_heavy (hashtext(payload));

-- 2M rows, ~3+ GB with all indexes at fillfactor=50 — far exceeds the
-- standby's 48 MB shared_buffers, forcing real disk I/O on replay.
INSERT INTO idx_heavy (id, acct_id, val1, val2, val3, val4, val5, val6, status, payload)
SELECT
    i,
    i % 10000,
    (random() * 1000000)::int,
    (random() * 1000000)::int,
    (random() * 1000000)::int,
    (random() * 1000000)::int,
    (random() * 1000000)::int,
    (random() * 1000000)::int,
    (i % 5)::smallint,
    repeat('x', 100 + (random() * 100)::int)
FROM generate_series(1, 2000000) AS i;

ANALYZE idx_heavy;
CHECKPOINT;
