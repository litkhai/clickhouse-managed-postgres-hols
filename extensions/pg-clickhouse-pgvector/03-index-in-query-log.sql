-- Lab 03 — Confirm on the ClickHouse side what EXPLAIN predicted in lab 02.
-- Each query is tagged with log_comment through pg_clickhouse.session_settings. Since 0.11.1 that GUC
-- overrides built-in settings by key, so the tag no longer drops join_use_nulls, final, etc.
-- system.query_log then shows, per tag, whether the HNSW index was searched (ProfileEvents
-- USearchSearchCount) and how many rows ClickHouse read.

\set qvec '(SELECT emb FROM hn_queries WHERE qid = 1)'
\pset pager off

SET pg_clickhouse.session_settings = 'log_comment pgvec_03_a_cosine_limit10';
SELECT count(*) AS rows_returned FROM (SELECT id FROM hn_docs ORDER BY emb <=> :qvec LIMIT 10) s;

SET pg_clickhouse.session_settings = 'log_comment pgvec_03_b_cosine_filter';
SELECT count(*) AS rows_returned FROM (SELECT id FROM hn_docs WHERE type = 1 ORDER BY emb <=> :qvec LIMIT 10) s;

SET pg_clickhouse.session_settings = 'log_comment pgvec_03_c_l2_on_cosine_index';
SELECT count(*) AS rows_returned FROM (SELECT id FROM hn_docs ORDER BY emb <-> :qvec LIMIT 10) s;

SET pg_clickhouse.session_settings = 'log_comment pgvec_03_d_farthest_first';
SELECT count(*) AS rows_returned FROM (SELECT id FROM hn_docs ORDER BY emb <=> :qvec DESC LIMIT 10) s;

SET pg_clickhouse.session_settings = 'log_comment pgvec_03_e_index_off, use_skip_indexes 0';
SELECT count(*) AS rows_returned FROM (SELECT id FROM hn_docs ORDER BY emb <=> :qvec LIMIT 10) s;

RESET pg_clickhouse.session_settings;

CALL clickhouse_perform('ch', 'SYSTEM FLUSH LOGS');

\echo ''
\echo '========== system.query_log, read through clickhouse_query() =========='
SELECT *
FROM clickhouse_query('ch', $$
    SELECT tag, hnsw_searches, read_rows, ms, final_sent, join_use_nulls_sent
    FROM (
        SELECT log_comment                                AS tag,
               ProfileEvents['USearchSearchCount']        AS hnsw_searches,
               read_rows,
               query_duration_ms                          AS ms,
               Settings['final']                          AS final_sent,
               Settings['join_use_nulls']                 AS join_use_nulls_sent
        FROM system.query_log
        WHERE type = 'QueryFinish'
          AND log_comment LIKE 'pgvec_03_%'
          AND query LIKE '%FROM default.hn_docs%'
        ORDER BY event_time_microseconds DESC
        LIMIT 1 BY log_comment
    )
    ORDER BY tag
$$) AS t(tag text, hnsw_searches bigint, read_rows bigint, ms bigint, final_sent text, join_use_nulls_sent text);
