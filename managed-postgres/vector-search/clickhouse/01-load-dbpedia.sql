-- Load the dbpedia embeddings into ClickHouse, straight from Hugging Face.
--
-- Runs ON CLICKHOUSE — paste into the SQL console or pipe through the HTTPS
-- interface. These are not psql statements.
--
-- 1M Wikipedia articles with 1536-dimension embeddings from OpenAI's
-- text-embedding-3-large, published as 26 Parquet files. No API key, no
-- download step, no embedding model: ClickHouse reads the Parquet over HTTPS
-- with url() and Postgres pulls from here in sql/02-load-from-clickhouse.sql.

-- --------------------------------------------------------------------------
-- The one setting you cannot skip
-- --------------------------------------------------------------------------
--
-- Hugging Face's dataset API answers with a chain of 302s to its CDN, and
-- ClickHouse refuses more than one redirect by default. Without this you get
--
--   Code: 483. DB::Exception: Too many redirects while trying to access …
--   The table structure cannot be extracted from a Parquet format file.
--
-- which reads like a broken file and is not one.
SET max_http_get_redirects = 10;

CREATE DATABASE IF NOT EXISTS vec;

CREATE TABLE IF NOT EXISTS vec.dbpedia
(
    id        String,
    title     String,
    body      String,
    embedding Array(Float32)
)
ENGINE = MergeTree
ORDER BY id;

-- --------------------------------------------------------------------------
-- Load
-- --------------------------------------------------------------------------
--
-- 26 files, 38,462 rows each, 1,000,000 rows in total. Start with one file
-- while you are finding your feet — the whole set is ~6 GB of Float32 once
-- unpacked, and every later step gets slower in proportion.
--
-- The source column name has dashes in it, so it needs backticks.

INSERT INTO vec.dbpedia
SELECT _id                                     AS id,
       title,
       text                                    AS body,
       arrayMap(x -> toFloat32(x),
                `text-embedding-3-large-1536-embedding`) AS embedding
FROM url('https://huggingface.co/api/datasets/Qdrant/dbpedia-entities-openai3-text-embedding-3-large-1536-1M/parquet/default/train/0.parquet',
         'Parquet');

-- All 26 files. Uncomment when you want the full million.
--
-- INSERT INTO vec.dbpedia
-- SELECT _id, title, text, arrayMap(x -> toFloat32(x), `text-embedding-3-large-1536-embedding`)
-- FROM url('https://huggingface.co/api/datasets/Qdrant/dbpedia-entities-openai3-text-embedding-3-large-1536-1M/parquet/default/train/{0..25}.parquet',
--          'Parquet');

-- --------------------------------------------------------------------------
-- The ClickHouse side of the comparison
-- --------------------------------------------------------------------------
--
-- A vector similarity index, HNSW backed by usearch. Available from 26.4.
--
--   parameters: method, metric, dimensions, quantization, M, ef_construction
--
-- bf16 is the default quantization and the docs report recall matching
-- Float32 — worth checking rather than believing, which is what the recall
-- harness in sql/03-ground-truth.sql is for.

ALTER TABLE vec.dbpedia
    ADD INDEX IF NOT EXISTS emb_idx embedding
    TYPE vector_similarity('hnsw', 'cosineDistance', 1536, 'bf16', 16, 64);

ALTER TABLE vec.dbpedia MATERIALIZE INDEX emb_idx SETTINGS mutations_sync = 2;

-- --------------------------------------------------------------------------
-- Check
-- --------------------------------------------------------------------------

SELECT count()                                   AS rows,
       length(any(embedding))                    AS dims,
       formatReadableSize(sum(byteSize(embedding))) AS embedding_bytes
FROM vec.dbpedia;

SELECT name,
       formatReadableSize(sum(data_compressed_bytes))   AS compressed,
       formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed
FROM system.columns
WHERE database = 'vec' AND table = 'dbpedia'
GROUP BY name ORDER BY sum(data_compressed_bytes) DESC;

-- One nearest-neighbour query, to prove the index answers.
WITH (SELECT embedding FROM vec.dbpedia LIMIT 1) AS q
SELECT title, round(cosineDistance(embedding, q), 4) AS dist
FROM vec.dbpedia
ORDER BY cosineDistance(embedding, q)
LIMIT 10;
