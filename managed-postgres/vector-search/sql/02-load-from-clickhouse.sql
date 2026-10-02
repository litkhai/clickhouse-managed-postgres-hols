-- Pull the embeddings from ClickHouse into Postgres.
--
--   ./scripts/psql.sh -f /sql/02-load-from-clickhouse.sql
--
-- The ClickHouse connection comes from CH_HOST, CH_PORT, CH_USER, CH_PASSWORD and
-- CH_DATABASE in config.env (see _clickhouse-vars.sql), so the password stays out
-- of the command line and out of `ps`. -v still works and wins:
--
--   ./scripts/psql.sh -v ch_host=xxx.clickhouse.cloud -v ch_pass='...' \
--       -f /sql/02-load-from-clickhouse.sql
--
-- ClickHouse already has the data (clickhouse/01-load-dbpedia.sql), so this is
-- a copy between two managed services rather than another trip to Hugging
-- Face. The FDW moves the arrays in ClickHouse's binary protocol.
--
-- The alternative — piping Parquet through a text pipeline into COPY — works
-- and is painfully slow: measured here at roughly 3,000 rows/minute for
-- 1536-dimension vectors, because every float becomes a decimal string and
-- every row carries ~20 KB of text. A million rows that way is not an
-- afternoon.

\ir _clickhouse-vars.sql
-- \quit inside an included file only ends that file, so check the outcome here.
\if :{?ch_vars_ok}
\else
  \quit
\endif

CREATE EXTENSION IF NOT EXISTS pg_clickhouse;

DROP SERVER IF EXISTS vec_ch_svr CASCADE;

CREATE SERVER vec_ch_svr
    FOREIGN DATA WRAPPER clickhouse_fdw
    OPTIONS (host :'ch_host', port :'ch_port', dbname :'ch_db',
             secure 'true', driver 'binary');

CREATE USER MAPPING FOR CURRENT_USER
    SERVER vec_ch_svr
    OPTIONS (user :'ch_user', password :'ch_pass');

DROP SCHEMA IF EXISTS vec_ch CASCADE;
CREATE SCHEMA vec_ch;

IMPORT FOREIGN SCHEMA :"ch_db"
    LIMIT TO (dbpedia)
    FROM SERVER vec_ch_svr
    INTO vec_ch;

-- --------------------------------------------------------------------------
-- Copy across
-- --------------------------------------------------------------------------
--
-- ClickHouse hands back Array(Float32), which pg_clickhouse surfaces as a
-- Postgres array. pgvector's input parser wants square brackets:
--
--   ERROR: invalid input syntax for type vector: "{-0.0018529714,0.0224…}"
--   DETAIL: Vector contents must start with "[".
--
-- So the braces get translated. There is no direct array-to-vector cast in
-- pgvector 0.8.x, and this is the shortest correct bridge.

\timing on

INSERT INTO vec.dbpedia (id, title, body, embedding)
SELECT id, title, body, translate(embedding::text, '{}', '[]')::vector(1536)
FROM vec_ch.dbpedia
ON CONFLICT (id) DO NOTHING;

\timing off

-- --------------------------------------------------------------------------
-- The query set
-- --------------------------------------------------------------------------

TRUNCATE vec.queries;
INSERT INTO vec.queries (qid, id, title, embedding)
SELECT row_number() OVER (ORDER BY md5(id)), id, title, embedding
FROM vec.dbpedia
ORDER BY md5(id)
LIMIT 20;

\echo ''
\echo '== loaded =='
SELECT count(*)                                                AS rows,
       pg_size_pretty(pg_total_relation_size('vec.dbpedia'))    AS total,
       pg_size_pretty(pg_relation_size('vec.dbpedia'))          AS heap,
       pg_size_pretty(pg_total_relation_size('vec.dbpedia')
                    - pg_relation_size('vec.dbpedia'))          AS toast_and_indexes,
       (SELECT vector_dims(embedding) FROM vec.dbpedia LIMIT 1) AS dims
FROM vec.dbpedia;

\echo ''
\echo '-- Note the split. The heap is small; the vectors are all in TOAST.'
\echo '-- Measured on a real service at 38,462 rows: 16 MB heap, 322 MB total,'
\echo '-- and the FDW moved all of it in 38.9 s.'
