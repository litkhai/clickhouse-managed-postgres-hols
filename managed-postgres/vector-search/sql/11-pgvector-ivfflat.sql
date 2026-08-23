-- pgvector, IVFFlat.
--
--   ./scripts/psql.sh -f /sql/11-pgvector-ivfflat.sql
--
-- The older of pgvector's two indexes and, on this data, the one that makes
-- the cost of HNSW's build time obvious.

\timing on

DROP INDEX IF EXISTS vec.idx_hnsw;
DROP INDEX IF EXISTS vec.idx_vchord;
DROP INDEX IF EXISTS vec.idx_ivfflat;

SET max_parallel_maintenance_workers = 0;
SET maintenance_work_mem = '1GB';

-- lists = how many Voronoi cells to cluster the vectors into. pgvector's own
-- guidance is rows/1000 up to 1M rows, then sqrt(rows) beyond that.
--
-- IVFFlat has a property HNSW does not: it must be built on data that is
-- already there. Build it on an empty table and every vector lands in one
-- cell, and the index is worthless without a REINDEX. Load first, always.
CREATE INDEX idx_ivfflat ON vec.dbpedia
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

\timing off

\echo ''
\echo '== size =='
SELECT pg_size_pretty(pg_relation_size('vec.idx_ivfflat')) AS index_size;

\echo ''
\echo '== recall and latency at three probe counts =='
-- probes = how many cells to open at query time. One cell is fast and wrong;
-- all of them is exact and pointless.
SET max_parallel_workers_per_gather = 0;

SET ivfflat.probes = 1;
SELECT 'ivfflat probes=1'  AS method, vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;
SET ivfflat.probes = 10;
SELECT 'ivfflat probes=10' AS method, vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;
SET ivfflat.probes = 30;
SELECT 'ivfflat probes=30' AS method, vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;

\echo ''
\echo '-- Measured on a real service at 38,462 rows: probes=1 gave 0.700 at'
\echo '-- 1.05 ms, probes=10 gave 0.975 at 7.33 ms, probes=30 gave 0.995 at'
\echo '-- 21.44 ms. HNSW reached the same 0.975 in 1.45 ms — five times faster,'
\echo '-- for six times the build. That is the trade, and it is the whole point.'
