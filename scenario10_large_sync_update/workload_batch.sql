-- pgbench script: 50K-row batch UPDATE, committed synchronously.
--
-- Each transaction updates 50K rows across 3 columns with 4 index modifications
-- per row.  This generates ~30-60 MB of WAL per commit.
--
-- remote_write: the WAL streams ahead during execution; commit only waits
--               for the last WAL chunk (the COMMIT record) to be acked → fast.
--
-- remote_apply: the primary must wait for the standby to replay all 50K row
--               changes, which requires random I/O into 4 indexes + the heap.
--               Single-threaded replay at the tail of a 50 MB WAL burst.
--
-- Run with -c 2 or -c 4 (not 32) so each individual commit is large and the
-- per-commit latency is clearly visible in the 5-second progress output.

\set start random(1, 950000)

UPDATE big_updates
   SET a  = a  + 1,
       b  = b  + 1,
       ts = now()
 WHERE id BETWEEN :start AND :start + 49999;
