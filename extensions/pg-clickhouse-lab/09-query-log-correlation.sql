-- Lab 09 — From a pg_cron run to its statements in ClickHouse's system.query_log.
-- Needs steps 07 and 08 (their job history and log_comment tags). Everything runs from PostgreSQL:
-- system.query_log is read through clickhouse_query() on the same foreign server.

\echo '========== 1. Flush the log =========='

-- system.query_log is written every flush_interval_milliseconds (7500 in this image's config.xml).
CALL clickhouse_perform('ch_srv', 'SYSTEM FLUSH LOGS');

\echo ''
\echo '========== 2. Per job: one stable tag makes the runs comparable =========='

SELECT *
FROM clickhouse_query('ch_srv', $$
    SELECT log_comment, toString(type), toInt64(count()), toInt64(round(avg(query_duration_ms))),
           toInt64(sum(read_rows)), toInt64(max(memory_usage)), toInt32(max(exception_code))
    FROM   system.query_log
    WHERE  log_comment IN ('retl_full_refresh', 'retl_delta_sync')
      AND  type != 'QueryStart'
      AND  event_date >= yesterday()
    GROUP  BY ALL
    ORDER  BY 1, 2 $$)
    AS t(log_comment text, type text, statements bigint, avg_ms bigint, read_rows bigint, max_memory bigint, max_exception_code int);

\echo ''
\echo '========== 3. Per run: cron.job_run_details next to the ClickHouse statements of that run =========='

-- Both containers share one clock. A run's statements start between its start_time and end_time.
-- read_rows is what ClickHouse scanned; result_rows is what it sent to PostgreSQL.
WITH ch AS (
    SELECT *
    FROM clickhouse_query('ch_srv', $$
        SELECT log_comment, query_start_time_microseconds, read_rows, result_rows, exception_code
        FROM   system.query_log
        WHERE  log_comment IN ('retl_full_refresh', 'retl_delta_sync')
          AND  type != 'QueryStart'
          AND  event_date >= yesterday() $$)
        AS t(log_comment text, started timestamptz, read_rows bigint, result_rows bigint, exception_code int)
)
SELECT j.jobname, d.runid, d.status,
       to_char(d.start_time, 'HH24:MI:SS.MS') AS started,
       round(extract(epoch FROM d.end_time - d.start_time) * 1000) AS run_ms,
       count(ch.started) AS ch_statements,
       coalesce(sum(ch.read_rows), 0) AS ch_read_rows,
       coalesce(sum(ch.result_rows), 0) AS ch_result_rows,
       max(ch.exception_code) AS ch_exception_code,
       left(split_part(d.return_message, E'\n', 1), 60) AS return_message
FROM   cron.job_run_details d
JOIN   cron.job j USING (jobid)
LEFT   JOIN ch ON ch.log_comment = replace(j.jobname, '-', '_')
              AND ch.started BETWEEN d.start_time AND d.end_time
WHERE  j.jobname IN ('retl-full-refresh', 'retl-delta-sync')
GROUP  BY j.jobname, d.runid, d.status, d.start_time, d.end_time, d.return_message
ORDER  BY j.jobname, d.runid;

\echo ''
\echo '========== 4. Per statement: the Remote SQL is the query text ClickHouse logged =========='

EXPLAIN (VERBOSE)
SELECT item_id, score, labels, updated_at FROM ch.item_scores
WHERE  updated_at > '2026-01-01 00:00:00+00' AND updated_at <= '2026-01-02 00:00:00+00';

SELECT *
FROM clickhouse_query('ch_srv', $$
    SELECT log_comment, toString(type), any(query)
    FROM   system.query_log
    WHERE  log_comment = 'retl_delta_sync' AND type = 'QueryFinish' AND event_date >= yesterday()
    GROUP  BY ALL $$)
    AS t(log_comment text, type text, example_query text);

\echo ''
\echo '========== 5. EXPLAIN ANALYZE shows no ClickHouse query id =========='

-- pg_clickhouse 0.11.0 reports Relations, Remote SQL and FDW Time, nothing that names the statement in
-- ClickHouse. When one statement matters, give it a tag of its own.
SET pg_clickhouse.session_settings =
    'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, log_comment retl_one_statement';
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF) SELECT count(*) FROM ch.item_scores;
RESET pg_clickhouse.session_settings;

CALL clickhouse_perform('ch_srv', 'SYSTEM FLUSH LOGS');

SELECT *
FROM clickhouse_query('ch_srv', $$
    SELECT toString(query_id), toString(type), query_duration_ms, read_rows, query
    FROM   system.query_log
    WHERE  log_comment = 'retl_one_statement' AND type != 'QueryStart' AND event_date >= yesterday()
    ORDER  BY event_time_microseconds $$)
    AS t(query_id text, type text, duration_ms bigint, read_rows bigint, query text);

\echo ''
\echo '========== Lab 09 complete =========='
