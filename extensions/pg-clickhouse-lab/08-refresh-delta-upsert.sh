#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./cron-helpers.sh

JOB=retl-delta-sync
STATE="SELECT count(*) AS rows,
              count(*) FILTER (WHERE score = 4.0) AS rescored,
              count(*) FILTER (WHERE item_id BETWEEN 301 AND 304) AS deleted_items_left,
              count(*) FILTER (WHERE item_id BETWEEN 20001 AND 20003) AS new_items,
              count(*) FILTER (WHERE item_id = 401 AND score = 5.0) AS item_401_updated,
              (SELECT watermark FROM serving.sync_state WHERE name = 'item_scores') AS watermark
       FROM serving.item_scores_delta"

echo "==========================================================="
echo " pg_clickhouse Lab 08: Pattern B — delta upsert             "
echo "==========================================================="
echo ""

"${PSQL[@]}" < 08-refresh-delta-upsert.sql

echo ""
echo "========== 5. Positive check: updates, inserts and deletes arrive =========="
r0=$(last_runid $JOB)
echo "-- ClickHouse: items 201-250 get score 4.0, items 20001-20003 are new, items 301-304 are deleted"
"${CH[@]}" -n -q "
    INSERT INTO retl.item_scores SELECT item_id, 4.0, labels, now64(3, 'UTC') FROM retl.item_scores FINAL WHERE item_id BETWEEN 201 AND 250;
    INSERT INTO retl.item_scores SELECT number + 20001, 0.5, ['group-new'], now64(3, 'UTC') FROM numbers(3);
    INSERT INTO retl.item_scores_deleted SELECT number + 301, now64(3, 'UTC') FROM numbers(4);
    DELETE FROM retl.item_scores WHERE item_id BETWEEN 301 AND 304;"
# hi = now() - 5 s, so the first run that can see the change starts at least 5 s after it.
visible_from=$(pg_val "SELECT now() + interval '5 seconds'")
echo "-- waiting for a successful run that started 5 s after the change: $(wait_run $JOB "$r0" succeeded 30 "$visible_from")"
show_runs $JOB "$r0"
"${PSQL[@]}" -c "$STATE"
echo "-- ClickHouse, for comparison:"
"${CH[@]}" -q "SELECT count() AS rows, countIf(score = 4.0) AS rescored FROM retl.item_scores FINAL FORMAT PrettyCompactMonoBlock"

echo ""
echo "========== 6. Negative check: a failing cycle changes nothing =========="
r1=$(last_runid $JOB)
echo "-- ClickHouse: the tombstone table disappears (renamed), then item 401 gets score 5.0"
"${CH[@]}" -q "RENAME TABLE retl.item_scores_deleted TO retl.item_scores_deleted_paused"
"${CH[@]}" -q "INSERT INTO retl.item_scores SELECT item_id, 5.0, labels, now64(3, 'UTC') FROM retl.item_scores FINAL WHERE item_id = 401"
visible_from=$(pg_val "SELECT now() + interval '5 seconds'")
echo "-- waiting for a failed run whose window includes the change: $(wait_run $JOB "$r1" failed 30 "$visible_from")"
show_runs $JOB "$r1"
echo "-- the upsert of that cycle was rolled back with the failed DELETE: item 401 not updated, watermark unchanged"
"${PSQL[@]}" -c "$STATE"

r2=$(last_runid $JOB)
echo "-- ClickHouse: the tombstone table is back"
"${CH[@]}" -q "RENAME TABLE retl.item_scores_deleted_paused TO retl.item_scores_deleted"
echo "-- waiting for the next successful run: $(wait_run $JOB "$r2" succeeded 20)"
show_runs $JOB "$r2"
"${PSQL[@]}" -c "$STATE"

echo ""
echo "========== 7. Pause the job (step 09 reads its history) =========="
"${PSQL[@]}" -c "SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = '$JOB'" \
             -c "SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname = '$JOB'"

echo ""
echo "==========================================================="
echo " Lab 08 complete. Next: ./09-query-log-correlation.sh"
echo "==========================================================="
