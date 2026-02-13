-- pgbench script: realistic order lifecycle churn.
-- Deletes old completed orders + inserts new ones → generates dead tuples
-- that VACUUM will later try to clean up.

\set cid random(1, 50000)
\set amt random(1, 10000)

-- Archive old delivered/cancelled orders (creates dead tuples)
DELETE FROM orders
 WHERE id IN (
    SELECT id FROM orders
     WHERE status IN ('delivered', 'cancelled')
       AND created_at < now() - interval '60 days'
     ORDER BY created_at
     LIMIT 5
 );

-- Insert fresh orders to keep the table populated
INSERT INTO orders (customer_id, amount, status)
VALUES (:cid, :amt, 'pending');
