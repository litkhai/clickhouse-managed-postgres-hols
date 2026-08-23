-- VectorChord (vchordrq).
--
--   ./scripts/psql.sh -f /sql/12-vectorchord.sql
--
-- Managed Postgres ships this alongside pgvector, which is the interesting
-- part: the platform includes two vector engines rather than one. VectorChord
-- is IVF with RaBitQ quantisation — cells like IVFFlat, but the candidates
-- inside each cell are scored against compressed codes and only the survivors
-- are re-ranked against the full vectors.

\timing on

DROP INDEX IF EXISTS vec.idx_hnsw;
DROP INDEX IF EXISTS vec.idx_ivfflat;
DROP INDEX IF EXISTS vec.idx_vchord;

SET max_parallel_maintenance_workers = 0;
SET maintenance_work_mem = '1GB';

-- Options are TOML, not a WITH list. `lists` is the IVF cell count, same idea
-- as IVFFlat. residual_quantization improves accuracy for cosine/L2 by coding
-- the offset from the cell centroid rather than the raw vector.
CREATE INDEX idx_vchord ON vec.dbpedia
    USING vchordrq (embedding vector_cosine_ops)
    WITH (options = $$
residual_quantization = true
[build.internal]
lists = [100]
$$);

\timing off

\echo ''
\echo '== size =='
-- Do not expect the index to be small. RaBitQ compresses what is *scanned*,
-- not what is *stored*: the full vectors stay for re-ranking. The vendor's
-- "1B vectors in 64 MB" claim is about the resident working set, not disk.
-- Measured at 31,000 rows: 253 MB, slightly larger than either pgvector index.
SELECT pg_size_pretty(pg_relation_size('vec.idx_vchord')) AS index_size;

\echo ''
\echo '== recall and latency at three probe counts =='
SET max_parallel_workers_per_gather = 0;

SET vchordrq.probes = 1;
SELECT 'vectorchord probes=1'  AS method, vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;
SET vchordrq.probes = 10;
SELECT 'vectorchord probes=10' AS method, vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;
SET vchordrq.probes = 30;
SELECT 'vectorchord probes=30' AS method, vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;

\echo ''
\echo '-- If a query fails with "need N probes, but 0 probes provided", the'
\echo '-- planner chose this index in a session that never set vchordrq.probes.'
\echo '-- There is no default. That is a footgun worth knowing before it fires'
\echo '-- inside an application.'
