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
\echo '-- Measured at 31,000 rows: probes=1 gave recall 0.715 at 1.53 ms,'
\echo '-- probes=10 gave 0.965 at 3.77 ms, probes=30 gave 0.990 at 8.55 ms.'
\echo '-- Compare probes=10 against vchordrq probes=10: identical recall,'
\echo '-- twenty times the latency. That is the row that matters.'
