-- pgbench script: batch INSERT of 8 tickets with large TOAST bodies and GIN entries.
--
-- Each execution inserts 8 rows in one transaction, generating:
--   8 × heap INSERT with TOAST (10-30 KB per row = 80-240 KB TOAST WAL)
--   8 × GIN pending list entries for body_tsv, tags, metadata, title_trgm
--   8 × btree inserts for project_id, created_at, PK
--
-- GIN pending list flushes happen ~8x more often per commit (8 rows fill
-- the 64 KB gin_pending_list_limit faster), creating expensive replay
-- bursts. Each single-row INSERT added +1.2ms; 8 rows → ~+10ms.

\set proj random(1, 100)

INSERT INTO tickets (project_id, title, body, metadata, body_tsv, tags)
SELECT
    (:proj + i) % 100 + 1,
    'Auto ticket ' || txid_current() || '-' || i || '-' || md5(random()::text),
    repeat(
        'Automated test ticket for sync replication benchmarking. '
        || 'This simulates a real customer support ticket body with detailed '
        || 'reproduction steps and environment information. '
        || 'Hash: ' || md5(random()::text) || ' ' || md5(random()::text) || '. '
        || 'Stack trace: ' || md5(random()::text) || md5(random()::text) || '. ',
        10 + (random() * 20)::int
    ),
    jsonb_build_object(
        'priority', (ARRAY['low','medium','high','critical'])[1+(random()*3)::int],
        'assignee', 'user_' || (random()*50)::int,
        'labels', jsonb_build_array(
            (ARRAY['bug','feature','docs','perf','security'])[1+(random()*4)::int],
            'backend'
        ),
        'custom_fields', jsonb_build_object(
            'browser', 'chrome',
            'os', 'linux',
            'version', (random()*10)::int || '.' || (random()*20)::int,
            'env', 'prod',
            'notes', md5(random()::text) || md5(random()::text),
            'trace_id', md5(random()::text)
        )
    ),
    to_tsvector('english',
        'automated test ticket replication benchmark ' ||
        md5(random()::text) || ' ' || md5(random()::text)
    ),
    ARRAY[
        (ARRAY['bug','feature','task','improvement','question'])[1+(random()*4)::int],
        (ARRAY['p0','p1','p2','p3'])[1+(random()*3)::int],
        'proj-' || ((:proj + i) % 100 + 1)
    ]
FROM generate_series(1, 8) i;
