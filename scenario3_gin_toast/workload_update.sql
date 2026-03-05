-- pgbench script: batch UPDATE of 30 SCATTERED tickets (TOAST rewrite + GIN update).
--
-- Updates 30 rows SCATTERED across the 300K-row table (spaced 10,000 apart).
-- Each row lands on a different heap page and different GIN/btree leaf pages.
-- For each row:
--   1. Old TOAST chunks freed, new ones written (10-30 KB per row)
--   2. Old tsvector/tags/metadata GIN entries marked for cleanup
--   3. New GIN entries added to pending lists → triggers flushes
--   4. All replayed serially through one startup process
--
-- 30 scattered rows × (TOAST + 4 GIN indexes + 2 btree) ≈ 180+ distinct page
-- modifications per commit. Each page modification during replay requires a
-- buffer lookup + apply. Replay must process all serially.

\set seed random(1, 10000)
\set proj random(1, 100)

UPDATE tickets
SET body = repeat(
        'Updated ticket body for benchmarking synchronous replication modes. '
        || 'Comparing remote_write vs remote_apply latency under GIN + TOAST load. '
        || 'Hash: ' || md5(random()::text) || ' ' || md5(random()::text) || '. '
        || 'Details: ' || md5(random()::text) || md5(random()::text) || '. ',
        10 + (random() * 20)::int
    ),
    metadata = jsonb_set(
        jsonb_set(metadata, '{custom_fields,notes}', to_jsonb(md5(random()::text))),
        '{priority}',
        to_jsonb((ARRAY['low','medium','high','critical'])[1+(random()*3)::int])
    ),
    body_tsv = to_tsvector('english',
        'updated ticket replication test ' ||
        md5(random()::text) || ' ' || md5(random()::text)
    ),
    tags = ARRAY[
        (ARRAY['bug','feature','task','improvement','question'])[1+(random()*4)::int],
        (ARRAY['p0','p1','p2','p3'])[1+(random()*3)::int],
        'proj-' || :proj
    ]
WHERE id IN (
    SELECT :seed + (i - 1) * 10000
    FROM generate_series(1, 30) i
);
