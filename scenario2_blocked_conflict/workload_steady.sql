-- pgbench script: lightweight status updates (the "normal" write traffic).
-- These are the transactions whose latency we're measuring — they should be
-- fast under remote_write but will stall under remote_apply when replay
-- is blocked.

\set id random(1, 500000)

UPDATE orders
   SET status     = 'confirmed',
       updated_at = now()
 WHERE id = :id
   AND status = 'pending';
