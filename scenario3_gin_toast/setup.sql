-- Scenario 3: GIN index + TOAST — bursty apply pressure
--
-- WHY THIS WORKS:
-- GIN indexes use a "pending list" (fastupdate) that buffers insertions and
-- flushes them in bulk — either when the list exceeds gin_pending_list_limit
-- or during VACUUM. The flush generates a burst of WAL records that are
-- expensive to replay because GIN entry insertion involves posting tree
-- traversal, page splits, and compression of posting lists.
--
-- Additionally, TOAST operations (compressing/decompressing large values)
-- add CPU and I/O overhead during replay.
--
-- Tuned for maximum replay pain:
-- - Bodies 10-30KB (heavy TOAST)
-- - 4 GIN indexes including pg_trgm (very expensive to maintain)
-- - gin_pending_list_limit = 64 KB (flushes frequently → constant bursts)
-- - Standby has 48 MB shared_buffers + recovery_prefetch=off

DROP TABLE IF EXISTS tickets;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE tickets (
    id          serial PRIMARY KEY,
    project_id  integer     NOT NULL,
    title       text        NOT NULL,
    body        text        NOT NULL,       -- 10-30 KB → heavily TOASTed
    metadata    jsonb       NOT NULL,       -- ~2 KB → TOASTed
    body_tsv    tsvector    NOT NULL,
    tags        text[]      NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- GIN indexes: the expensive ones to replay
CREATE INDEX tickets_body_gin    ON tickets USING gin (body_tsv);
CREATE INDEX tickets_tags_gin    ON tickets USING gin (tags);
CREATE INDEX tickets_meta_gin    ON tickets USING gin (metadata jsonb_path_ops);

-- pg_trgm GIN on title: trigram decomposition is extremely expensive to
-- replay — each title generates dozens of trigram index entries, and the
-- GIN posting tree must be updated for each one.
CREATE INDEX tickets_title_trgm  ON tickets USING gin (title gin_trgm_ops);

-- Regular btree indexes
CREATE INDEX tickets_project_idx ON tickets (project_id);
CREATE INDEX tickets_created_idx ON tickets (created_at);

-- Small pending list limit: flush every 64 KB instead of 256 KB.
-- This means 4x more frequent GIN flushes → 4x more replay bursts.
ALTER INDEX tickets_body_gin   SET (fastupdate = on, gin_pending_list_limit = 64);
ALTER INDEX tickets_tags_gin   SET (fastupdate = on, gin_pending_list_limit = 64);
ALTER INDEX tickets_meta_gin   SET (fastupdate = on, gin_pending_list_limit = 64);
ALTER INDEX tickets_title_trgm SET (fastupdate = on, gin_pending_list_limit = 64);

-- Generate data with large TOAST bodies
INSERT INTO tickets (project_id, title, body, metadata, body_tsv, tags)
SELECT
    (random() * 100)::int,
    'Ticket #' || i || ': ' || md5(i::text) || ' ' || md5(random()::text),
    -- Body: 10-30 KB of text → heavily TOASTed, multiple TOAST chunks per row
    repeat(
        'Customer reported issue with ' || (ARRAY['login','payment','search','export','import'])[1+(random()*4)::int]
        || '. Steps to reproduce: ' || md5(random()::text) || ' '
        || md5(random()::text) || ' ' || md5(random()::text) || '. '
        || 'Expected behavior: ' || md5(random()::text) || '. '
        || 'Actual behavior: ' || md5(random()::text) || '. '
        || 'Environment details: OS=' || (ARRAY['linux','macos','windows'])[1+(random()*2)::int]
        || ' browser=' || (ARRAY['chrome','firefox','safari','edge'])[1+(random()*3)::int]
        || ' version=' || (random()*20)::int || '.' || (random()*99)::int || '. ',
        10 + (random() * 20)::int
    ),
    -- JSONB metadata: ~2 KB → also TOASTed
    jsonb_build_object(
        'priority', (ARRAY['low','medium','high','critical'])[1+(random()*3)::int],
        'assignee', 'user_' || (random()*50)::int,
        'labels', jsonb_build_array(
            (ARRAY['bug','feature','docs','perf','security'])[1+(random()*4)::int],
            (ARRAY['frontend','backend','infra','mobile','api'])[1+(random()*4)::int]
        ),
        'custom_fields', jsonb_build_object(
            'browser', (ARRAY['chrome','firefox','safari','edge'])[1+(random()*3)::int],
            'os', (ARRAY['linux','macos','windows','ios','android'])[1+(random()*4)::int],
            'version', (random()*10)::int || '.' || (random()*20)::int,
            'env', (ARRAY['prod','staging','dev'])[1+(random()*2)::int],
            'description', md5(random()::text) || md5(random()::text) || md5(random()::text),
            'notes', md5(random()::text) || md5(random()::text) || md5(random()::text),
            'trace_id', md5(random()::text),
            'session_id', md5(random()::text),
            'request_headers', jsonb_build_object(
                'user_agent', md5(random()::text),
                'referer', md5(random()::text),
                'accept', md5(random()::text)
            )
        )
    ),
    to_tsvector('english',
        'Ticket ' || i || ' customer issue ' ||
        (ARRAY['login','payment','search','export','import'])[1+(random()*4)::int] ||
        ' ' || md5(random()::text) || ' ' || md5(random()::text)
    ),
    ARRAY[
        (ARRAY['bug','feature','task','improvement','question'])[1+(random()*4)::int],
        (ARRAY['p0','p1','p2','p3'])[1+(random()*3)::int],
        'proj-' || (random()*100)::int,
        (ARRAY['linux','macos','windows'])[1+(random()*2)::int],
        (ARRAY['chrome','firefox','safari'])[1+(random()*2)::int]
    ]
FROM generate_series(1, 300000) AS i;

ANALYZE tickets;
CHECKPOINT;
