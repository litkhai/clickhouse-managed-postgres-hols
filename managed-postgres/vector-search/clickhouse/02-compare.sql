-- The ClickHouse side, measured the same way.
--
-- Runs ON CLICKHOUSE. Paste into the SQL console.
--
-- The comparison only means something if both engines are judged by the same
-- rule, so this rebuilds the same ground truth and the same recall@10 over the
-- same twenty queries.

SET max_http_get_redirects = 10;

-- --------------------------------------------------------------------------
-- The same query set
-- --------------------------------------------------------------------------
--
-- Chosen by the same md5 ordering as the Postgres side, so the two labs are
-- asking the identical twenty questions.

CREATE TABLE IF NOT EXISTS vec.queries
(
    qid       UInt32,
    id        String,
    embedding Array(Float32)
)
ENGINE = MergeTree ORDER BY qid;

TRUNCATE TABLE vec.queries;

INSERT INTO vec.queries
SELECT rowNumberInAllBlocks() + 1 AS qid, id, embedding
FROM (SELECT id, embedding FROM vec.dbpedia ORDER BY lower(hex(MD5(id))) LIMIT 20);

-- --------------------------------------------------------------------------
-- Ground truth, brute force
-- --------------------------------------------------------------------------
--
-- Turning the index off is what makes this exact. Without the setting
-- ClickHouse will happily use the vector index and hand you approximate
-- answers as your reference, which quietly guarantees recall 1.000.

CREATE TABLE IF NOT EXISTS vec.truth (qid UInt32, id String, rnk UInt32)
ENGINE = MergeTree ORDER BY (qid, rnk);

TRUNCATE TABLE vec.truth;

INSERT INTO vec.truth
SELECT qid, id, rnk FROM (
    SELECT q.qid AS qid, d.id AS id,
           row_number() OVER (PARTITION BY q.qid ORDER BY cosineDistance(d.embedding, q.embedding)) AS rnk
    FROM vec.queries q CROSS JOIN vec.dbpedia d
) WHERE rnk <= 10
SETTINGS vector_search_index_fetch_multiplier = 1, use_skip_indexes = 0;

-- --------------------------------------------------------------------------
-- Recall of the vector similarity index
-- --------------------------------------------------------------------------
--
-- hnsw_candidate_list_size_for_search is ClickHouse's ef_search. Sweep it the
-- same way the Postgres files sweep theirs.

SELECT 'ef_search=64' AS method, round(avg(hits) / 10.0, 3) AS recall
FROM (
    SELECT q.qid,
           (SELECT count() FROM (
                SELECT d.id FROM vec.dbpedia d
                ORDER BY cosineDistance(d.embedding, q.embedding) LIMIT 10
            ) r INNER JOIN vec.truth t ON t.qid = q.qid AND t.id = r.id) AS hits
    FROM vec.queries q
) SETTINGS hnsw_candidate_list_size_for_search = 64;

-- --------------------------------------------------------------------------
-- What it costs
-- --------------------------------------------------------------------------

SELECT name,
       formatReadableSize(sum(data_compressed_bytes)) AS compressed
FROM system.columns
WHERE database = 'vec' AND table = 'dbpedia' AND name = 'embedding'
GROUP BY name;

SELECT type, name, formatReadableSize(data_compressed_bytes) AS on_disk
FROM system.data_skipping_indices
WHERE database = 'vec' AND table = 'dbpedia';

-- Compare this against the Postgres numbers. The row that matters is not
-- "which is faster" — it is what each engine charges in bytes to answer at the
-- same recall, because that is what decides where a billion vectors can live.
