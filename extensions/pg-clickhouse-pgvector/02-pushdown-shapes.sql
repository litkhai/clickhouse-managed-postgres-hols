-- Lab 02 — Which pgvector query shapes pg_clickhouse 0.11.1 pushes down, and which can use the
-- ClickHouse vector similarity index. EXPLAIN (VERBOSE) shows the Remote SQL that ClickHouse runs
-- and, for nearest-neighbour searches, the "Vector Index" lines pg_clickhouse adds.
-- The query vector is held-out row qid = 1 of hn_queries; pg_clickhouse sends it as a parameter.

\set qvec '(SELECT emb FROM hn_queries WHERE qid = 1)'

\echo '========== A. Nearest 10 by cosine distance (<=>): index ann is used =========='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id, title, emb <=> :qvec AS distance
FROM   hn_docs
ORDER  BY emb <=> :qvec
LIMIT  10;

SELECT id, left(coalesce(nullif(title, ''), text), 70) AS title_or_text, round((emb <=> :qvec)::numeric, 4) AS distance
FROM   hn_docs
ORDER  BY emb <=> :qvec
LIMIT  10;

\echo ''
\echo '========== B. Same search with a WHERE filter: still pushed down, index still used =========='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id
FROM   hn_docs
WHERE  type = 1
ORDER  BY emb <=> :qvec
LIMIT  10;

\echo ''
\echo '========== C. L2 distance (<->) against a cosine index: pushed down, no index =========='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id FROM hn_docs ORDER BY emb <-> :qvec LIMIT 10;

\echo ''
\echo '========== D. Inner product (<#>): sorts as dotProduct DESC, no index (the index is cosine) =========='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id FROM hn_docs ORDER BY emb <#> :qvec LIMIT 10;

\echo ''
\echo '========== E. Farthest first (DESC): planner warning, no index =========='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id FROM hn_docs ORDER BY emb <=> :qvec DESC LIMIT 10;

\echo ''
\echo '========== F. No LIMIT: planner warning, no index (EXPLAIN only: it would fetch every vector) =========='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id FROM hn_docs ORDER BY emb <=> :qvec;

\echo ''
\echo '========== G. LIMIT above max_limit_for_vector_search_queries (1000 in ClickHouse 26.9.7.9) =========='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id FROM hn_docs ORDER BY emb <=> :qvec LIMIT 2000;

\echo ''
\echo '========== H. Distance in WHERE with an aggregate: the whole query runs in ClickHouse (exact, no index) =========='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT type, count(*) FROM hn_docs WHERE emb <=> :qvec < 0.5 GROUP BY type ORDER BY type;

SELECT type, count(*) FROM hn_docs WHERE emb <=> :qvec < 0.5 GROUP BY type ORDER BY type;

\echo ''
\echo '========== I. Distance and vector_dims() in the SELECT list: computed in Postgres =========='
\echo '   (Remote SQL fetches emb itself; fine for LIMIT k, costly without a LIMIT)'
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id, vector_dims(emb), cosine_distance(emb, :qvec) FROM hn_docs WHERE id < 1000;
