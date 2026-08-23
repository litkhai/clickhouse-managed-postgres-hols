-- Exact answers, and the harness that measures everything against them.
--
--   ./scripts/psql.sh -f /sql/03-ground-truth.sql
--
-- Run this with NO vector index present. Brute force is the point: it is the
-- only result that is correct by definition, and it is also the baseline the
-- approximate methods have to beat on time.
--
-- A vector benchmark that reports speed without recall is measuring nothing.
-- Any index can be made arbitrarily fast by looking at fewer candidates.

\timing on

-- --------------------------------------------------------------------------
-- Ground truth
-- --------------------------------------------------------------------------
--
-- Parallelism off so the timing means "one core doing the full scan", which
-- is the number the approximate methods should be compared against.

SET max_parallel_workers_per_gather = 0;

TRUNCATE vec.truth;

INSERT INTO vec.truth (qid, id, rnk)
SELECT q.qid, a.id,
       row_number() OVER (PARTITION BY q.qid ORDER BY q.embedding <=> a.embedding)
FROM vec.queries q
CROSS JOIN LATERAL (
    SELECT id, embedding
    FROM vec.dbpedia
    ORDER BY q.embedding <=> embedding
    LIMIT 10
) a;

\timing off

-- --------------------------------------------------------------------------
-- The harness
-- --------------------------------------------------------------------------
--
-- recall@10 = how many of the exact top-10 the index actually returned,
-- averaged over the query set. Call it after setting whichever GUC the
-- current index reads (hnsw.ef_search, ivfflat.probes, vchordrq.probes).

CREATE OR REPLACE FUNCTION vec.recall_at_10()
RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT round(avg(hits) / 10.0, 3)
    FROM (
        SELECT (
            SELECT count(*)
            FROM (SELECT a.id
                    FROM vec.dbpedia a
                   ORDER BY a.embedding <=> q.embedding
                   LIMIT 10) r
            JOIN vec.truth t ON t.qid = q.qid AND t.id = r.id
        ) AS hits
        FROM vec.queries q
    ) x;
$$;

-- Wall-clock for the whole query set. Divide by the number of queries for
-- per-query latency. Deliberately not a single query: one cold lookup tells
-- you about the page cache, not about the index.
CREATE OR REPLACE FUNCTION vec.sweep()
RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp(); n integer;
BEGIN
    PERFORM (SELECT count(*)
               FROM vec.queries q
               CROSS JOIN LATERAL (SELECT a.id FROM vec.dbpedia a
                                    ORDER BY a.embedding <=> q.embedding
                                    LIMIT 10) r);
    SELECT count(*) INTO n FROM vec.queries;
    RETURN round((extract(epoch FROM clock_timestamp() - t0) * 1000 / n)::numeric, 2);
END $$;

\echo ''
\echo '== baseline: exact search, no index =='
SELECT count(DISTINCT qid) AS queries,
       count(*)            AS truth_rows
FROM vec.truth;

SET max_parallel_workers_per_gather = 0;
SELECT vec.recall_at_10() AS recall, vec.sweep() AS ms_per_query;

\echo ''
\echo '-- recall must be 1.000 here. If it is not, the truth table is stale:'
\echo '-- rebuild it after any change to vec.dbpedia or vec.queries.'
