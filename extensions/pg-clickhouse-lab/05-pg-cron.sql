-- Lab 05 (PostgreSQL side) — pg_cron, and the ClickHouse source as foreign tables.
-- Needs steps 00-01 (extension, ch_srv, user mapping). Step 05's runner seeds ClickHouse first.

\echo '========== 1. Versions read from the running builds =========='

SELECT version();
SELECT clickhouse_server_version('ch_srv') AS clickhouse_version;

-- PostgreSQL 18 lists loaded libraries with the version they declare. pg_clickhouse declares one;
-- pg_cron 1.6.8 does not, so its version comes from the package (the runner prints it above).
LOAD 'pg_clickhouse';
SELECT module_name, version, file_name FROM pg_get_loaded_modules() ORDER BY file_name;

\echo ''
\echo '========== 2. pg_cron: preloaded at server start, then CREATE EXTENSION =========='

-- shared_preload_libraries is set on the postgres command line in docker-compose.yml.
-- It needs a server start; a reconnect is not enough. pg_clickhouse needs neither.
SHOW shared_preload_libraries;
SHOW cron.database_name;
SHOW cron.use_background_workers;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_clickhouse', 'pg_cron') ORDER BY 1;

\echo ''
\echo '========== 3. Every run is a new session =========='

-- With cron.use_background_workers = off (the default), pg_cron opens a libpq connection
-- for each run. Nothing set in your own session (SET ...) reaches the job.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'retl-probe';
SELECT cron.schedule('retl-probe', '5 seconds', $$SELECT 1$$) AS jobid;

SELECT pg_sleep(11);

SELECT d.runid, d.job_pid, d.status, d.return_message
FROM   cron.job_run_details d
JOIN   cron.job j USING (jobid)
WHERE  j.jobname = 'retl-probe'
ORDER  BY d.runid;

SELECT cron.unschedule('retl-probe');

\echo ''
\echo '========== 4. The ClickHouse source as foreign tables =========='

DROP SCHEMA IF EXISTS ch CASCADE;
CREATE SCHEMA ch;
IMPORT FOREIGN SCHEMA retl FROM SERVER ch_srv INTO ch;

\d ch.item_scores

-- IMPORT FOREIGN SCHEMA records the engine name only: 'ReplacingMergeTree', without (updated_at).
-- pg_clickhouse 0.11.0 does not derive FINAL from this option. Deduplication comes from the
-- session setting final 1 (step 06).
SELECT ftrelid::regclass AS foreign_table, ftoptions
FROM   pg_foreign_table
WHERE  ftrelid IN ('ch.item_scores'::regclass, 'ch.item_scores_deleted'::regclass)
ORDER  BY 1;

SELECT count(*) AS items FROM ch.item_scores;

\echo ''
\echo '========== Lab 05 complete =========='
\echo 'Next: ./06-session-settings-and-tagging.sh'
