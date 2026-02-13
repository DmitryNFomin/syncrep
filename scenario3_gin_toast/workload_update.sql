-- pgbench script: update ticket body + metadata (TOAST rewrite + GIN update).
--
-- This is particularly nasty for replay because:
-- 1. The old TOAST chunks must be freed, new ones written
-- 2. The old tsvector GIN entries must eventually be cleaned up
-- 3. New GIN entries are added to the pending list
-- 4. All of this is serialized through one startup process

\set id random(1, 300000)
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
WHERE id = :id;
