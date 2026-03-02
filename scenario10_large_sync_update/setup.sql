-- Scenario 10: Large synchronous UPDATE — I/O-heavy replay
--
-- MECHANISM (answering "shouldn't it be ≈2× slower?"):
--
-- For any transaction:
--
--   remote_write commit latency:
--     The primary streams WAL to the standby continuously as the transaction
--     executes.  By the time the primary writes the COMMIT WAL record, most
--     of the transaction's WAL is already in the standby's OS page cache.
--     remote_write only waits for the COMMIT record itself to be ack'd.
--     → commit overhead ≈ network RTT (milliseconds), regardless of txn size.
--
--   remote_apply commit latency:
--     The primary must wait for the standby to fully REPLAY all WAL generated
--     by the transaction before returning success.  The standby's single-
--     threaded startup process must read each modified heap page, apply the
--     change, update each index entry — all serially, often with cold cache.
--     → commit overhead ≈ replay_time, which can equal or exceed execution_time.
--
-- Therefore:
--   remote_write total = execution_time + RTT              ≈ T + ms
--   remote_apply total = execution_time + replay_time      ≈ T + T = 2T  (equal HW)
--                        execution_time + replay_time      ≈ T + 3T = 4T (standby I/O-bound)
--
-- Table design: 1M rows, 4 secondary indexes.
-- Each updated row requires: 1 heap update + 4 index entry replacements.
-- fillfactor=80 leaves 20% free space for HOT updates; setting it intentionally
-- low (not 50) so the table stays reasonably compact but HOT updates are
-- limited — forcing index updates that amplify replay cost.

DROP TABLE IF EXISTS big_updates CASCADE;

CREATE TABLE big_updates (
    id    bigint PRIMARY KEY,
    a     int    NOT NULL,
    b     int    NOT NULL,
    c     text   NOT NULL,   -- md5, 32 chars, not updated in the batch script
    ts    timestamptz NOT NULL DEFAULT now()
) WITH (fillfactor = 80);

-- Secondary indexes — each UPDATE to (a, b, ts) must update all three
CREATE INDEX big_upd_a   ON big_updates (a);
CREATE INDEX big_upd_b   ON big_updates (b);
CREATE INDEX big_upd_a_b ON big_updates (a, b);
CREATE INDEX big_upd_ts  ON big_updates (ts);

-- 1M rows: ~300 bytes each → ~300 MB heap + ~120 MB indexes ≈ 420 MB total.
-- Exceeds a memory-constrained standby's shared_buffers → lots of I/O on replay.
INSERT INTO big_updates (id, a, b, c, ts)
SELECT
    i,
    (i % 50000)::int,
    (i % 30000)::int,
    md5(i::text),
    now() - make_interval(secs => (random() * 86400)::int)
FROM generate_series(1, 1000000) i;

ANALYZE big_updates;
CHECKPOINT;
