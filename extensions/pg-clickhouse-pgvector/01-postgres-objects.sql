-- Lab 01 (Postgres side) — foreign server and foreign tables over the ClickHouse tables,
-- plus a local pgvector copy of the same documents with an HNSW index, for comparison in lab 04.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_clickhouse;

DROP SERVER IF EXISTS ch CASCADE;
-- 0.11.1 uses the binary (native protocol) driver by default.
CREATE SERVER ch FOREIGN DATA WRAPPER clickhouse_fdw OPTIONS (host 'clickhouse', dbname 'default');
CREATE USER MAPPING FOR CURRENT_USER SERVER ch OPTIONS (user 'default', password '');

-- A pgvector vector column maps to the ClickHouse Array(Float32) column (pg_clickhouse 0.11.1).
CREATE FOREIGN TABLE hn_docs (
    id bigint, type smallint, by text, time timestamp, title text, text text, emb vector(384)
) SERVER ch OPTIONS (table_name 'hn_docs');
CREATE FOREIGN TABLE hn_queries (qid int, source_id bigint, emb vector(384)) SERVER ch OPTIONS (table_name 'hn_queries');
CREATE FOREIGN TABLE hn_truth (qid int, ids bigint[]) SERVER ch OPTIONS (table_name 'hn_truth');

SELECT clickhouse_server_version('ch') AS clickhouse, pgch_version() AS pg_clickhouse,
       (SELECT extversion FROM pg_extension WHERE extname = 'vector') AS pgvector;

\timing on
DROP TABLE IF EXISTS hn_docs_local;
CREATE TABLE hn_docs_local AS SELECT id, emb FROM hn_docs;
ALTER TABLE hn_docs_local ADD PRIMARY KEY (id);
-- Same graph parameters as the ClickHouse index (M 32, ef_construction 128); pgvector stores float32,
-- ClickHouse quantizes its graph to bf16 by default.
CREATE INDEX hn_docs_local_hnsw ON hn_docs_local USING hnsw (emb vector_cosine_ops) WITH (m = 32, ef_construction = 128);
\timing off
ANALYZE hn_docs_local;

SELECT count(*) AS local_rows, pg_size_pretty(pg_relation_size('hn_docs_local_hnsw')) AS hnsw_index_size FROM hn_docs_local;
