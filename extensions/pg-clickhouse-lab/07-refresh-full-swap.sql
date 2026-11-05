-- Lab 07 — Pattern A: rebuild the serving table from ClickHouse every cycle and swap it in.
-- Needs step 05 (ch.item_scores). The runner schedules the job and runs the checks.

\echo '========== 1. Serving table and a reader role =========='

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'retl-full-refresh';

DROP SCHEMA IF EXISTS serving CASCADE;
CREATE SCHEMA serving;

DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_reader') THEN CREATE ROLE app_reader; END IF;
END $$;
GRANT USAGE ON SCHEMA serving TO app_reader;

-- CREATE TABLE ... (LIKE ... INCLUDING ALL) copies columns, defaults, constraints and indexes,
-- but not privileges. Default privileges give every table the job creates here the reader's grant.
ALTER DEFAULT PRIVILEGES IN SCHEMA serving GRANT SELECT ON TABLES TO app_reader;

CREATE TABLE serving.item_scores
(
    item_id    bigint PRIMARY KEY,
    score      double precision NOT NULL,
    labels     text[] NOT NULL,
    updated_at timestamptz(3) NOT NULL
);
CREATE INDEX ON serving.item_scores (updated_at);

\echo ''
\echo '========== 2. The refresh function: one transaction per cycle =========='

CREATE OR REPLACE FUNCTION serving.refresh_item_scores() RETURNS void
LANGUAGE plpgsql AS $fn$
BEGIN
    -- Keep the four defaults (step 06) and tag every statement this job sends to ClickHouse.
    -- SET LOCAL ends with the transaction, so nothing stays on the connection.
    SET LOCAL pg_clickhouse.session_settings =
        'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, log_comment retl_full_refresh';

    CREATE TABLE serving.item_scores_new (LIKE serving.item_scores INCLUDING ALL);

    -- Filters and aggregates in this SELECT would run in ClickHouse; only result rows travel.
    INSERT INTO serving.item_scores_new (item_id, score, labels, updated_at)
    SELECT item_id, score, labels, updated_at
    FROM   ch.item_scores;

    -- Fresh statistics, so the first query after the swap gets a sensible plan.
    ANALYZE serving.item_scores_new;

    -- The renames need ACCESS EXCLUSIVE on the live table. Give up quickly behind a long reader;
    -- the next cycle tries again, and readers keep the previous snapshot meanwhile.
    SET LOCAL lock_timeout = '3s';

    ALTER TABLE serving.item_scores     RENAME TO item_scores_old;
    ALTER TABLE serving.item_scores_new RENAME TO item_scores;
    DROP TABLE serving.item_scores_old;
END;
$fn$;

\echo ''
\echo '========== 3. One cycle by hand, three times =========='

SELECT serving.refresh_item_scores();
SELECT serving.refresh_item_scores();
SELECT serving.refresh_item_scores();

SELECT count(*) AS rows, count(DISTINCT item_id) AS items,
       has_table_privilege('app_reader', 'serving.item_scores', 'SELECT') AS reader_can_select
FROM   serving.item_scores;

-- Index names come from the first CREATE TABLE ... LIKE and are chosen to avoid collisions on every cycle.
SELECT indexrelid::regclass AS index FROM pg_index WHERE indrelid = 'serving.item_scores'::regclass ORDER BY 1;

\echo ''
\echo '-- A view on the live table follows the renamed old table, so DROP fails and the whole cycle rolls back (expect an ERROR)'
CREATE VIEW serving.item_scores_top AS SELECT * FROM serving.item_scores WHERE score > 0.9;
SELECT serving.refresh_item_scores();
DROP VIEW serving.item_scores_top;

\echo ''
\echo '========== 4. Schedule it every 5 seconds =========='

SELECT cron.schedule('retl-full-refresh', '5 seconds', $$SELECT serving.refresh_item_scores()$$) AS jobid;
