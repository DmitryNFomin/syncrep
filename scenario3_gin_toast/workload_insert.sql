-- pgbench script: insert new tickets with large bodies and JSONB metadata.
--
-- Each INSERT generates:
-- 1. Heap INSERT (with TOAST — body is 2-8KB, metadata ~1KB)
-- 2. GIN pending list entries for body_tsv, tags, metadata (3 indexes)
-- 3. B-tree inserts for project_id, created_at, PK
--
-- When the GIN pending lists flush (every gin_pending_list_limit KB),
-- it creates a burst of WAL that is very expensive to replay.

\set proj random(1, 100)
\set issue_type random(1, 5)
\set priority random(1, 4)
\set tag1_idx random(1, 5)
\set tag2_idx random(1, 5)

INSERT INTO tickets (project_id, title, body, metadata, body_tsv, tags)
VALUES (
    :proj,
    'Auto ticket ' || txid_current() || '-' || md5(random()::text),
    -- 10-30 KB body → heavily TOASTed (multiple TOAST chunks)
    repeat(
        'Automated test ticket for sync replication benchmarking. '
        || 'This simulates a real customer support ticket body with detailed '
        || 'reproduction steps and environment information. '
        || 'Hash: ' || md5(random()::text) || ' ' || md5(random()::text) || '. '
        || 'Stack trace: ' || md5(random()::text) || md5(random()::text) || '. ',
        10 + (random() * 20)::int
    ),
    jsonb_build_object(
        'priority', (ARRAY['low','medium','high','critical'])[:priority],
        'assignee', 'user_' || (random()*50)::int,
        'labels', jsonb_build_array(
            (ARRAY['bug','feature','docs','perf','security'])[:issue_type],
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
        (ARRAY['bug','feature','task','improvement','question'])[:tag1_idx],
        (ARRAY['p0','p1','p2','p3'])[:tag2_idx],
        'proj-' || :proj
    ]
);
