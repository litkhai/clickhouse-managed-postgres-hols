-- pgvector, HNSW.
--
--   ./scripts/psql.sh -f /sql/10-pgvector-hnsw.sql
--
-- Only one vector index may exist at a time in this lab. The planner picks by
-- cost and will not let you choose, so each of these files drops the others
-- first. That is deliberate: comparing indexes means running them alone.

\timing on

DROP INDEX IF EXISTS vec.idx_ivfflat;
DROP INDEX IF EXISTS vec.idx_vchord;
DROP INDEX IF EXISTS vec.idx_hnsw;

-- Parallel index build asks for a large shared-memory segment, and Docker
-- gives a container 64 MB of /dev/shm by default:
--
--   ERROR: could not resize shared memory segment … No space left on device
--
-- Either start the container with --shm-size=2g or build on one worker. On a
-- managed service this does not arise; it bites when you rehearse locally.
SET max_parallel_maintenance_workers = 0;
SET maintenance_work_mem = '1GB';

-- m               edges per node. Higher = better recall, bigger index, slower build.
-- ef_construction candidate list while building. Higher = better graph, slower build.
CREATE INDEX idx_hnsw ON vec.dbpedia
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

\timing off

\echo ''
\echo '== size =='
-- Expect roughly the size of the vectors themselves. HNSW keeps full-precision
-- copies in its graph, so the index does not compress anything. Measured on a
-- real service at 38,462 rows: 300 MB of index against a 322 MB table, and the
-- build took 68 s.
SELECT pg_size_pretty(pg_relation_size('vec.idx_hnsw')) AS index_size,
       pg_size_pretty(pg_total_relation_size('vec.dbpedia')
                    - pg_relation_size('vec.idx_hnsw')) AS table_without_index;

\echo ''
\echo '== recall and latency at three search widths =='
-- ef_search is the only knob at query time: how many candidates to keep while
-- descending the graph. It trades recall for time, and it is where an honest
-- comparison has to happen — matched on recall, not on default settings.
SET max_parallel_workers_per_gather = 0;

SET hnsw.ef_search = 20;
SELECT 'hnsw ef_search=20'  AS method, vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;
SET hnsw.ef_search = 40;
SELECT 'hnsw ef_search=40'  AS method, vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;
SET hnsw.ef_search = 100;
SELECT 'hnsw ef_search=100' AS method, vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;

\echo ''
\echo '== is the index actually being used? =='
-- "Index Scan using idx_hnsw" is what you want. A Seq Scan here means the
-- planner priced the index out — usually because the ORDER BY operator does
-- not match the opclass (<=> is cosine; <-> is L2; <#> is inner product).
SET hnsw.ef_search = 40;
EXPLAIN (COSTS OFF)
SELECT id FROM vec.dbpedia
ORDER BY embedding <=> (SELECT embedding FROM vec.queries WHERE qid = 1)
LIMIT 10;
