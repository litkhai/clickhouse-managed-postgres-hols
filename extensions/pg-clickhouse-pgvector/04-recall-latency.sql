-- Lab 04 — recall@10 and latency for the 100 held-out query vectors in hn_queries.
-- Ground truth is hn_truth: an exact top 10 per query, computed in ClickHouse by brute force in lab 01.
--
--   ch_index      foreign table, ORDER BY <=> LIMIT 10, ClickHouse HNSW index (defaults)
--   ch_exact      foreign table, same query with use_skip_indexes 0 (exact scan in ClickHouse)
--   ch_query_ids  clickhouse_query() with the same search selecting only id (ClickHouse HNSW index)
--   pg_hnsw_ef40  local pgvector table, HNSW index, hnsw.ef_search 40 (pgvector default)
--   pg_hnsw_ef256 local pgvector table, HNSW index, hnsw.ef_search 256 (ClickHouse's search default)
--   pg_exact      local pgvector table, index scans off (exact sequential scan)
--
-- Each method runs every query twice; only the second pass is timed. Times are wall-clock in the
-- Postgres backend (clock_timestamp), so ch_* include the round trip to ClickHouse.

\pset pager off
\timing off

\echo '========== The query the loop runs pushes ORDER BY ... LIMIT 10 down (note: the Remote SQL selects emb too) =========='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT array_agg(id) FROM (SELECT id FROM hn_docs ORDER BY emb <=> (SELECT emb FROM hn_queries WHERE qid = 1) LIMIT 10) s;

DROP TABLE IF EXISTS knn_runs;
CREATE TEMP TABLE knn_runs (method text, qid int, ids bigint[], ms double precision);

CREATE OR REPLACE FUNCTION pg_temp.run_method(method text, sql text, settings text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    q   record;
    ids bigint[];
    t0  timestamptz;
    pass int;
BEGIN
    PERFORM set_config('pg_clickhouse.session_settings', coalesce(settings, '') ||
            CASE WHEN settings IS NULL THEN '' ELSE ', ' END || 'log_comment pgvec_04_' || method, true);
    FOR pass IN 1..2 LOOP
        FOR q IN SELECT qid, emb FROM hn_queries_local ORDER BY qid LOOP
            t0 := clock_timestamp();
            EXECUTE sql INTO ids USING q.emb;
            IF pass = 2 THEN
                INSERT INTO knn_runs VALUES (method, q.qid, ids,
                    extract(epoch FROM clock_timestamp() - t0) * 1000);
            END IF;
        END LOOP;
    END LOOP;
END
$fn$;

-- Query vectors and truth are copied to local tables so the loops do not query ClickHouse for them.
DROP TABLE IF EXISTS hn_queries_local, hn_truth_local;
CREATE TEMP TABLE hn_queries_local AS SELECT qid, emb FROM hn_queries;
CREATE TEMP TABLE hn_truth_local   AS SELECT qid, ids FROM hn_truth;

BEGIN;
SELECT pg_temp.run_method('ch_index',
    'SELECT array_agg(id) FROM (SELECT id FROM hn_docs ORDER BY emb <=> $1 LIMIT 10) s');
COMMIT;
BEGIN;
SELECT pg_temp.run_method('ch_exact',
    'SELECT array_agg(id) FROM (SELECT id FROM hn_docs ORDER BY emb <=> $1 LIMIT 10) s', 'use_skip_indexes 0');
COMMIT;
BEGIN;
SELECT pg_temp.run_method('ch_query_ids', $sql$
    SELECT array_agg(id)
    FROM clickhouse_query('ch', format(
        'SELECT id FROM default.hn_docs ORDER BY cosineDistance(emb, CAST(%L AS Array(Float32))) LIMIT 10', $1::text))
        AS t(id bigint)
$sql$);
COMMIT;
BEGIN;
SET LOCAL hnsw.ef_search = 40;
SELECT pg_temp.run_method('pg_hnsw_ef40',
    'SELECT array_agg(id) FROM (SELECT id FROM hn_docs_local ORDER BY emb <=> $1 LIMIT 10) s');
COMMIT;
BEGIN;
SET LOCAL hnsw.ef_search = 256;
SELECT pg_temp.run_method('pg_hnsw_ef256',
    'SELECT array_agg(id) FROM (SELECT id FROM hn_docs_local ORDER BY emb <=> $1 LIMIT 10) s');
COMMIT;
BEGIN;
SET LOCAL enable_indexscan = off;
SELECT pg_temp.run_method('pg_exact',
    'SELECT array_agg(id) FROM (SELECT id FROM hn_docs_local ORDER BY emb <=> $1 LIMIT 10) s');
COMMIT;

\echo ''
\echo '========== recall@10 and latency (second pass, 100 queries) =========='
SELECT r.method,
       round(avg((SELECT count(*) FROM unnest(r.ids) x WHERE x = ANY (t.ids)) / 10.0), 3) AS recall_at_10,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY r.ms)::numeric, 2) AS p50_ms,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY r.ms)::numeric, 2) AS p95_ms,
       count(*) AS queries
FROM   knn_runs r JOIN hn_truth_local t USING (qid)
GROUP  BY r.method
ORDER  BY array_position(ARRAY['ch_index', 'ch_exact', 'ch_query_ids', 'pg_hnsw_ef40', 'pg_hnsw_ef256', 'pg_exact'], r.method);

\echo ''
\echo '========== ClickHouse side: query_duration_ms and HNSW searches per method (second pass) =========='
CALL clickhouse_perform('ch', 'SYSTEM FLUSH LOGS');
SELECT *
FROM clickhouse_query('ch', $$
    SELECT log_comment AS tag,
           count()                                          AS queries,
           quantileExact(0.5)(query_duration_ms)            AS p50_ms,
           quantileExact(0.95)(query_duration_ms)           AS p95_ms,
           sum(ProfileEvents['USearchSearchCount'])         AS hnsw_searches,
           round(avg(read_rows))                            AS avg_read_rows,
           formatReadableSize(avg(read_bytes))              AS avg_read_bytes
    FROM (
        SELECT * FROM system.query_log
        WHERE type = 'QueryFinish' AND log_comment LIKE 'pgvec_04_ch_%'
        ORDER BY event_time_microseconds DESC
        LIMIT 100 BY log_comment
    )
    GROUP BY tag ORDER BY tag
$$) AS t(tag text, queries bigint, p50_ms bigint, p95_ms bigint, hnsw_searches bigint, avg_read_rows double precision, avg_read_bytes text);
