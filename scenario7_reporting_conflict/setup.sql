-- Scenario 7: Standby reporting query blocks replay (realistic variant of S2)
--
-- WHY THIS WORKS:
-- Same mechanism as Scenario 2, but triggered by a REAL analytics query
-- instead of pg_sleep(). This demonstrates the production pattern:
--
--   1. A reporting dashboard runs a multi-minute GROUP BY on the standby
--   2. The query holds a REPEATABLE READ snapshot for its entire duration
--   3. Meanwhile, the primary DELETEs rows and VACUUMs (normal maintenance)
--   4. VACUUM generates PRUNE WAL that conflicts with the standby's snapshot
--   5. With max_standby_streaming_delay = -1, replay PAUSES instead of
--      canceling the reporting query
--   6. Under remote_apply: all primary writes freeze until the report finishes
--   7. Under remote_write: writes are unaffected
--
-- This is arguably the #1 reason people get burned by remote_apply in
-- production: using a standby for both HA replication and reporting.

DROP TABLE IF EXISTS sales CASCADE;
DROP TABLE IF EXISTS probe_s7 CASCADE;

CREATE TABLE sales (
    id          bigserial    PRIMARY KEY,
    region      text         NOT NULL,
    product_id  integer      NOT NULL,
    quantity    integer      NOT NULL,
    amount      numeric(12,2) NOT NULL,
    ts          timestamptz  NOT NULL,
    customer_id integer      NOT NULL
);

INSERT INTO sales (region, product_id, quantity, amount, ts, customer_id)
SELECT
    (ARRAY['us-east','us-west','eu-west','eu-central','apac'])[1+(random()*4)::int],
    (random() * 1000)::int + 1,
    (random() * 20)::int + 1,
    (random() * 500 + 10)::numeric(12,2),
    now() - make_interval(days => (random() * 365)::int),
    (random() * 50000)::int + 1
FROM generate_series(1, 1000000);

CREATE INDEX sales_ts          ON sales(ts);
CREATE INDEX sales_region_ts   ON sales(region, ts);
CREATE INDEX sales_customer    ON sales(customer_id);

-- Probe table
CREATE TABLE probe_s7 (
    id  serial PRIMARY KEY,
    val integer NOT NULL DEFAULT 0,
    ts  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO probe_s7 (val) SELECT generate_series(1, 10000);

ANALYZE;
CHECKPOINT;
