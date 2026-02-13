-- Churn workload for sales table: creates dead tuples from many small transactions
-- Run BEFORE the blocker query to create VACUUM conflicts.

\set id random(1, 1000000)
\set cid random(1, 50000)

-- Delete a few rows (creates dead tuples)
DELETE FROM sales
 WHERE id IN (
    SELECT id FROM sales
     WHERE region = 'us-east'
     ORDER BY id
     LIMIT 3
 );

-- Insert a replacement row (keeps table populated)
INSERT INTO sales (region, product_id, quantity, amount, ts, customer_id)
VALUES ('us-east', (:id % 1000) + 1, (:id % 20) + 1,
        (random() * 500 + 10)::numeric(12,2), now(), :cid);
