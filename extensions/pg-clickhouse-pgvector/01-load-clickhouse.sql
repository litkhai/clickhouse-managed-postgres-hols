-- Lab 01 (ClickHouse side) — split the downloaded rows into documents and held-out queries,
-- build the HNSW index, and compute the exact top 10 per query as ground truth.
-- hn_raw is filled by 01-load.sh from the public Hacker News all-MiniLM-L6-v2 dataset (384 dims).

DROP TABLE IF EXISTS hn_docs;
DROP TABLE IF EXISTS hn_queries;
DROP TABLE IF EXISTS hn_truth;

DROP TABLE IF EXISTS hn_clean;

-- About one row in eight of the slice is a comment or story with no text ("<by>: " only), and those share
-- a handful of identical vectors; a few thousand more repeat another row's vector. Keep rows with at least
-- 60 characters of text, one row per distinct vector, so ties do not blur recall.
CREATE TABLE hn_clean ENGINE = MergeTree ORDER BY id AS
SELECT id, type, by, toDateTime(time) AS time, title, text, vector
FROM hn_raw
WHERE length(text) >= 60
ORDER BY id
LIMIT 1 BY cityHash64(vector);

-- 100 held-out query vectors: the first 100 rows by cityHash64(id); they are not in hn_docs.
CREATE TABLE hn_queries (qid UInt32, source_id Int64, emb Array(Float32)) ENGINE = MergeTree ORDER BY qid;
INSERT INTO hn_queries
SELECT row_number() OVER (ORDER BY cityHash64(id)) AS qid, id, vector
FROM (SELECT id, vector FROM hn_clean ORDER BY cityHash64(id) LIMIT 100);

-- Documents with one HNSW vector similarity index on cosine distance. Parameters are the
-- defaults (quantization bf16, M 32, ef_construction 128) and GRANULARITY is the default (100 million),
-- so each part has one HNSW graph.
CREATE TABLE hn_docs
(
    id    Int64,
    type  Int8,
    by    String,
    time  DateTime,
    title String,
    text  String,
    emb   Array(Float32),
    INDEX ann emb TYPE vector_similarity('hnsw', 'cosineDistance', 384)
)
ENGINE = MergeTree
ORDER BY id;

INSERT INTO hn_docs
SELECT id, type, by, time, title, text, vector
FROM hn_clean
WHERE id NOT IN (SELECT source_id FROM hn_queries);

-- One part, so one graph covers every row (the index is rebuilt by this merge).
OPTIMIZE TABLE hn_docs FINAL;

-- Ground truth: exact cosine top 10 for each query, by brute force (no index involved).
CREATE TABLE hn_truth (qid UInt32, ids Array(Int64)) ENGINE = MergeTree ORDER BY qid;
INSERT INTO hn_truth
SELECT q.qid, arrayMap(x -> x.2, groupArraySorted(10)((cosineDistance(d.emb, q.emb), d.id)))
FROM hn_queries AS q CROSS JOIN hn_docs AS d
GROUP BY q.qid;

SELECT 'hn_raw' AS table, count() AS rows FROM hn_raw
UNION ALL SELECT 'hn_clean', count() FROM hn_clean
UNION ALL SELECT 'hn_docs', count() FROM hn_docs
UNION ALL SELECT 'hn_queries', count() FROM hn_queries
UNION ALL SELECT 'hn_truth', count() FROM hn_truth;

SELECT table, count() AS active_parts, sum(rows) AS rows,
       formatReadableSize(sum(secondary_indices_compressed_bytes)) AS vector_index_size
FROM system.parts WHERE active AND database = 'default' AND table = 'hn_docs' GROUP BY table;
