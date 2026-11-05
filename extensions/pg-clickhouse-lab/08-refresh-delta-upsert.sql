-- Lab 08 — Pattern B: apply only what changed since the last cycle (watermark + upsert + tombstones).
-- Needs steps 05 and 07 (schema serving). The runner schedules the job and runs the checks.

\echo '========== 1. Target table and watermark =========='

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'retl-delta-sync';

DROP TABLE IF EXISTS serving.item_scores_delta, serving.sync_state;

CREATE TABLE serving.item_scores_delta
(
    item_id    bigint PRIMARY KEY,
    score      double precision NOT NULL,
    labels     text[] NOT NULL,
    updated_at timestamptz(3) NOT NULL
);

CREATE TABLE serving.sync_state
(
    name      text PRIMARY KEY,
    watermark timestamptz NOT NULL
);
INSERT INTO serving.sync_state VALUES ('item_scores', '1970-01-01 00:00:00+00');

\echo ''
\echo '========== 2. The sync function: one transaction per cycle =========='

-- Requirements on the ClickHouse side: updated_at is the ReplacingMergeTree version column and only
-- grows per item; a delete writes a tombstone to retl.item_scores_deleted.
CREATE OR REPLACE FUNCTION serving.sync_item_scores() RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
    lo timestamptz;
    hi timestamptz := now() - interval '5 seconds';   -- rows written in the last 5 s wait for the next cycle
BEGIN
    SET LOCAL pg_clickhouse.session_settings =
        'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, log_comment retl_delta_sync';

    -- FOR UPDATE: a manual call and a scheduled run cannot both move the watermark.
    -- Reading one minute back overlaps the previous window; the upsert makes that harmless.
    SELECT watermark - interval '1 minute' INTO lo
    FROM   serving.sync_state WHERE name = 'item_scores' FOR UPDATE;

    INSERT INTO serving.item_scores_delta AS t (item_id, score, labels, updated_at)
    SELECT item_id, score, labels, updated_at
    FROM   ch.item_scores
    WHERE  updated_at > lo AND updated_at <= hi
    ON CONFLICT (item_id) DO UPDATE
       SET score = excluded.score, labels = excluded.labels, updated_at = excluded.updated_at
     WHERE t.updated_at < excluded.updated_at;          -- rows re-read in the overlap are skipped

    -- A tombstone removes the row unless the item was written again after the delete.
    DELETE FROM serving.item_scores_delta s
    USING  ch.item_scores_deleted d
    WHERE  s.item_id = d.item_id
      AND  d.deleted_at > lo AND d.deleted_at <= hi
      AND  s.updated_at <= d.deleted_at;

    UPDATE serving.sync_state SET watermark = hi WHERE name = 'item_scores';
END;
$fn$;

\echo ''
\echo '========== 3. The first cycle loads everything older than now() - 5 s =========='

SELECT serving.sync_item_scores();
SELECT count(*) AS rows FROM serving.item_scores_delta;
SELECT name, watermark FROM serving.sync_state;

\echo ''
\echo '========== 4. Schedule it every 5 seconds =========='

SELECT cron.schedule('retl-delta-sync', '5 seconds', $$SELECT serving.sync_item_scores()$$) AS jobid;
