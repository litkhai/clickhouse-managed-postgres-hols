-- Postgres side of the vector comparison.
--
--   ./scripts/psql.sh -f /sql/01-schema.sql
--
-- One table. Three indexes will be built on it in turn, never at the same
-- time — the planner picks one and you would spend the rest of the lab
-- fighting it for control.

CREATE EXTENSION IF NOT EXISTS vector;          -- pgvector: hnsw, ivfflat

-- VectorChord needs to be in shared_preload_libraries, and on ClickHouse
-- Managed Postgres it is not:
--
--   ERROR: vchord must be loaded via shared_preload_libraries.
--
-- You cannot fix that yourself either — ALTER SYSTEM is refused on the
-- service. Being listed in the extension catalogue is not the same as being
-- usable. So this is attempted and survives failing; sql/12-vectorchord.sql
-- then has nothing to build on, which is the honest outcome rather than a
-- broken lab.
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
    RAISE NOTICE 'vchord installed — sql/12-vectorchord.sql will run';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'vchord unavailable (%) — skip sql/12-vectorchord.sql', SQLERRM;
END
$$;

CREATE SCHEMA IF NOT EXISTS vec;

CREATE TABLE IF NOT EXISTS vec.dbpedia (
    id        text PRIMARY KEY,
    title     text,
    body      text,
    -- 1536 Float32 = 6,148 bytes per row once pgvector's header is counted,
    -- which is far past the 2 KB TOAST threshold. Every vector therefore lives
    -- out of line in the TOAST table, and the heap stays tiny while the total
    -- does not. Measured on 31,000 rows: 14 MB heap, 261 MB total.
    embedding vector(1536)
);

-- The query set. Twenty vectors drawn from the corpus itself, so every query
-- has a known perfect answer (itself, at distance 0) and 1M candidates behind
-- it. Sampling by md5 rather than random() keeps the set reproducible.
CREATE TABLE IF NOT EXISTS vec.queries (
    qid       integer PRIMARY KEY,
    id        text,
    title     text,
    embedding vector(1536)
);

-- Exact top-10 for each query, computed once by brute force. Everything else
-- in this lab is measured against it.
CREATE TABLE IF NOT EXISTS vec.truth (
    qid  integer,
    id   text,
    rnk  integer,
    PRIMARY KEY (qid, rnk)
);

\echo ''
\echo '== extensions =='
SELECT extname, extversion FROM pg_extension
WHERE extname IN ('vector', 'vchord') ORDER BY 1;

\echo ''
\echo '== access methods now available =='
SELECT amname FROM pg_am WHERE amtype = 'i' AND amname IN ('hnsw', 'ivfflat', 'vchordrq')
ORDER BY 1;
