-- Run this ON THE STANDBY to block WAL replay.
--
-- This simulates a reporting query that an analyst might run:
-- "give me a daily revenue report for the last 90 days"
--
-- The key is that this holds a snapshot open for a long time (pg_sleep).
-- While this snapshot is open, the startup process cannot replay VACUUM
-- records that remove tuples visible to this snapshot.
--
-- PREREQUISITES on standby postgresql.conf:
--   max_standby_streaming_delay = -1    -- never cancel standby queries
--   hot_standby_feedback = off          -- don't hold back primary's vacuum
--
-- The hot_standby_feedback=off is CRITICAL: if it's on, the primary won't
-- vacuum the rows at all, so there's no conflict and no blocking.

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- Take a snapshot by touching the table
SELECT count(*), sum(amount)
  FROM orders
 WHERE status = 'delivered';

-- Hold the snapshot open for 90 seconds.
-- During this time, any VACUUM WAL that conflicts will block replay.
SELECT pg_sleep(90);

-- The analytics "report"
SELECT
    date_trunc('day', created_at) AS day,
    count(*)                      AS order_count,
    sum(amount)                   AS revenue
FROM orders
WHERE created_at > now() - interval '90 days'
GROUP BY 1
ORDER BY 1;

COMMIT;
