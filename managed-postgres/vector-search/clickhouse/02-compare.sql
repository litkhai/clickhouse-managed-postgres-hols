-- The ClickHouse side, measured the same way.
--
-- Runs ON CLICKHOUSE. Paste into the SQL console.
--
-- The comparison only means something if both engines are judged by the same
-- rule, so this rebuilds the same ground truth and the same recall@10 over the
-- same twenty queries.
--
-- Database: mpg_hols_vec. A dedicated database name, so the lab can run on a shared
-- ClickHouse service without touching anything else on it.

SET max_http_get_redirects = 10;

-- --------------------------------------------------------------------------
-- The same query set
-- --------------------------------------------------------------------------
--
-- Chosen by the same md5 ordering as the Postgres side, so the two labs are
-- asking the identical twenty questions.

CREATE TABLE IF NOT EXISTS mpg_hols_vec.queries
(
    qid       UInt32,
    id        String,
    embedding Array(Float32)
)
ENGINE = MergeTree ORDER BY qid;

TRUNCATE TABLE mpg_hols_vec.queries;

INSERT INTO mpg_hols_vec.queries
SELECT rowNumberInAllBlocks() + 1 AS qid, id, embedding
FROM (SELECT id, embedding FROM mpg_hols_vec.dbpedia ORDER BY lower(hex(MD5(id))) LIMIT 20);

-- --------------------------------------------------------------------------
-- Ground truth, brute force
-- --------------------------------------------------------------------------
--
-- Turning the index off is what makes this exact. Without the setting
-- ClickHouse will happily use the vector index and hand you approximate
-- answers as your reference, which quietly guarantees recall 1.000.

CREATE TABLE IF NOT EXISTS mpg_hols_vec.truth (qid UInt32, id String, rnk UInt32)
ENGINE = MergeTree ORDER BY (qid, rnk);

TRUNCATE TABLE mpg_hols_vec.truth;

INSERT INTO mpg_hols_vec.truth
SELECT qid, id, rnk FROM (
    SELECT q.qid AS qid, d.id AS id,
           row_number() OVER (PARTITION BY q.qid ORDER BY cosineDistance(d.embedding, q.embedding)) AS rnk
    FROM mpg_hols_vec.queries q CROSS JOIN mpg_hols_vec.dbpedia d
) WHERE rnk <= 10
SETTINGS vector_search_index_fetch_multiplier = 1, use_skip_indexes = 0;

-- --------------------------------------------------------------------------
-- Recall of the vector similarity index
-- --------------------------------------------------------------------------
--
-- hnsw_candidate_list_size_for_search is ClickHouse's ef_search. The original
-- file measured only 64, and so does this one.
--
-- Twenty statements instead of one correlated subquery (q.embedding inside the
-- per-query ORDER BY ... LIMIT 10). Local 26.5.7, 26.6.8 and 26.9.7 reject that
-- with "Code: 48 ... Correlated subqueries are not supported in JOINs yet"; Cloud
-- 26.6.1 with "UNSUPPORTED_METHOD ... allow_experimental_correlated_subqueries".
-- An experimental setting is not worth enabling for a comparison, so each query
-- is unrolled and its reference vector is a constant the index can serve.

CREATE TABLE IF NOT EXISTS mpg_hols_vec.ann_results
(method String, qid UInt32, id String)
ENGINE = MergeTree ORDER BY (method, qid);

TRUNCATE TABLE mpg_hols_vec.ann_results;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 1) AS q
SELECT 'ef_search=64', 1, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 2) AS q
SELECT 'ef_search=64', 2, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 3) AS q
SELECT 'ef_search=64', 3, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 4) AS q
SELECT 'ef_search=64', 4, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 5) AS q
SELECT 'ef_search=64', 5, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 6) AS q
SELECT 'ef_search=64', 6, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 7) AS q
SELECT 'ef_search=64', 7, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 8) AS q
SELECT 'ef_search=64', 8, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 9) AS q
SELECT 'ef_search=64', 9, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 10) AS q
SELECT 'ef_search=64', 10, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 11) AS q
SELECT 'ef_search=64', 11, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 12) AS q
SELECT 'ef_search=64', 12, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 13) AS q
SELECT 'ef_search=64', 13, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 14) AS q
SELECT 'ef_search=64', 14, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 15) AS q
SELECT 'ef_search=64', 15, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 16) AS q
SELECT 'ef_search=64', 16, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 17) AS q
SELECT 'ef_search=64', 17, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 18) AS q
SELECT 'ef_search=64', 18, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 19) AS q
SELECT 'ef_search=64', 19, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

INSERT INTO mpg_hols_vec.ann_results
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 20) AS q
SELECT 'ef_search=64', 20, id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

-- 20 queries x 10 neighbours = 200 rows. Anything else means a statement above
-- was edited or skipped.
SELECT method, count() AS rows
FROM mpg_hols_vec.ann_results
GROUP BY method;

SELECT r.method, round(count() / 200.0, 3) AS recall
FROM mpg_hols_vec.ann_results r
INNER JOIN mpg_hols_vec.truth t ON t.qid = r.qid AND t.id = r.id
GROUP BY r.method;

-- --------------------------------------------------------------------------
-- Is the index actually being used?
-- --------------------------------------------------------------------------
--
-- The same SELECT as the qid = 1 statement above, without the INSERT. The plan
-- should list emb_idx as a vector_similarity index.

EXPLAIN indexes = 1
WITH (SELECT embedding FROM mpg_hols_vec.queries WHERE qid = 1) AS q
SELECT id
FROM mpg_hols_vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10
SETTINGS hnsw_candidate_list_size_for_search = 64;

-- --------------------------------------------------------------------------
-- What it costs
-- --------------------------------------------------------------------------
--
-- The table, from system.tables. Per-column sizes read 0.00 B on ClickHouse
-- Cloud 26.6.1 in both system.columns and system.parts_columns, so the table
-- total is the readout that is populated there. It needs no extra grant.
SELECT formatReadableSize(total_bytes)              AS compressed,
       formatReadableSize(total_bytes_uncompressed) AS uncompressed,
       total_rows
FROM system.tables
WHERE database = 'mpg_hols_vec' AND name = 'dbpedia';

-- The index, from the skipping-index view.
-- A restricted user needs SELECT ON system.data_skipping_indices.
SELECT type, name, formatReadableSize(data_compressed_bytes) AS on_disk
FROM system.data_skipping_indices
WHERE database = 'mpg_hols_vec' AND table = 'dbpedia';

-- Compare this against the Postgres numbers. The row that matters is not
-- "which is faster" — it is what each engine charges in bytes to answer at the
-- same recall, because that is what decides where a billion vectors can live.
