#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./cron-helpers.sh

JOB=retl-full-refresh

echo "==========================================================="
echo " pg_clickhouse Lab 07: Pattern A — full refresh + swap      "
echo "==========================================================="
echo ""

"${PSQL[@]}" < 07-refresh-full-swap.sql

echo ""
echo "========== 5. Positive check: ClickHouse changes arrive with the next swap =========="
r0=$(last_runid $JOB)
echo "-- ClickHouse: new versions of items 101-200 (score 2.0) and five new items 10001-10005"
"${CH[@]}" -n -q "
    INSERT INTO retl.item_scores SELECT item_id, 2.0, labels, now64(3, 'UTC') FROM retl.item_scores FINAL WHERE item_id BETWEEN 101 AND 200;
    INSERT INTO retl.item_scores SELECT number + 10001, 0.5, ['group-new'], now64(3, 'UTC') FROM numbers(5);"
echo "-- waiting for the next successful run: $(wait_run $JOB "$r0" succeeded 20)"
show_runs $JOB "$r0"
"${PSQL[@]}" -c "SELECT count(*) AS rows, count(*) FILTER (WHERE score = 2.0) AS rescored,
                        has_table_privilege('app_reader', 'serving.item_scores', 'SELECT') AS reader_can_select
                 FROM serving.item_scores"
echo "-- ClickHouse, for comparison:"
"${CH[@]}" -q "SELECT count() AS rows, countIf(score = 2.0) AS rescored FROM retl.item_scores FINAL FORMAT PrettyCompactMonoBlock"

echo ""
echo "========== 6. Negative check: a long reader blocks the swap =========="
r1=$(last_runid $JOB)
echo "-- a reader holds ACCESS SHARE on serving.item_scores for 12 s"
docker exec -d pgch-postgres psql -U postgres -X -c "BEGIN; SELECT count(*) FROM serving.item_scores; SELECT pg_sleep(12); COMMIT;"
echo "-- ClickHouse: items 201-210 get score 3.0 meanwhile"
"${CH[@]}" -q "INSERT INTO retl.item_scores SELECT item_id, 3.0, labels, now64(3, 'UTC') FROM retl.item_scores FINAL WHERE item_id BETWEEN 201 AND 210"

echo "-- waiting until the job's rename is queued behind that reader..."
for i in $(seq 1 15); do
    w=$(pg_val "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE '%refresh_item_scores%'")
    [ "$w" -gt 0 ] && break
    sleep 0.5
done
echo "   jobs waiting on a lock: $w"
echo "-- a new reader now queues behind the waiting rename until lock_timeout (3 s) cancels it:"
"${PSQL[@]}" -c '\timing on' -c "SELECT count(*) AS rows, count(*) FILTER (WHERE score = 3.0) AS new_scores_visible FROM serving.item_scores"

echo "-- waiting for the failed run: $(wait_run $JOB "$r1" failed 20)"
echo "-- and for the next successful one, after the reader commits: $(wait_run $JOB "$r1" succeeded 30)"
show_runs $JOB "$r1"
"${PSQL[@]}" -c "SELECT count(*) AS rows, count(*) FILTER (WHERE score = 3.0) AS new_scores_visible FROM serving.item_scores"

echo ""
echo "========== 7. Pause the job (step 09 reads its history) =========="
"${PSQL[@]}" -c "SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = '$JOB'" \
             -c "SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname = '$JOB'"

echo ""
echo "==========================================================="
echo " Lab 07 complete. Next: ./08-refresh-delta-upsert.sh"
echo "==========================================================="
