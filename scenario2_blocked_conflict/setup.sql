-- Scenario 2: Block WAL apply with a standby query conflict
--
-- WHY THIS WORKS:
-- When a long-running query on the standby holds a snapshot, and VACUUM on
-- the primary generates WAL records that remove tuples visible to that
-- snapshot, the startup process CANNOT replay those records without
-- invalidating the query. With max_standby_streaming_delay = -1, it waits.
--
-- During this wait, ALL replay stops — not just for the conflicting relation.
-- Every transaction committed on the primary with synchronous_commit =
-- remote_apply will hang until the standby query finishes (or is canceled).
--
-- This is extremely realistic: read replicas running reporting/analytics
-- queries is one of the primary use cases for streaming replication.

DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS order_archive;

-- A typical orders table — the "hot" table that gets constant writes
CREATE TABLE orders (
    id          serial PRIMARY KEY,
    customer_id integer   NOT NULL,
    amount      numeric(12,2) NOT NULL,
    status      text      NOT NULL DEFAULT 'pending',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX orders_customer_idx ON orders (customer_id);
CREATE INDEX orders_status_idx   ON orders (status);
CREATE INDEX orders_created_idx  ON orders (created_at);

-- Fill with 500K rows — enough to make queries take meaningful time
INSERT INTO orders (customer_id, amount, status, created_at)
SELECT
    (random() * 50000)::int,
    (random() * 10000)::numeric(12,2),
    (ARRAY['pending','confirmed','shipped','delivered','cancelled'])[1 + (random()*4)::int],
    now() - (random() * interval '90 days')
FROM generate_series(1, 500000);

ANALYZE orders;
CHECKPOINT;
