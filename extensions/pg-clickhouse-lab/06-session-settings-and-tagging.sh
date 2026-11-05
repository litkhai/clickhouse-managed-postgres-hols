#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PSQL=(docker exec -i pgch-postgres psql -U postgres -X)
CH=(docker exec -i pgch-clickhouse clickhouse-client)

echo "==========================================================="
echo " pg_clickhouse Lab 06: session_settings, log_comment, readonly"
echo "==========================================================="
echo ""

"${PSQL[@]}" < 06-session-settings-and-tagging.sql

echo ""
echo "========== 4. A fresh session, like a pg_cron run =========="
echo ""
echo "-- Before anything of pg_clickhouse is used, the parameter does not exist yet (positive control):"
"${PSQL[@]}" -c "SELECT count(*) AS defined FROM pg_settings WHERE name = 'pg_clickhouse.session_settings'"
echo "-- SET it first, then query (no LOAD, no session_preload_libraries):"
"${PSQL[@]}" \
    -c "SET pg_clickhouse.session_settings = 'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, log_comment retl_set_before_load'" \
    -c "SELECT count(*) AS rows_for_item_1 FROM ch.versions_demo WHERE item_id = 1" \
    -c "SHOW pg_clickhouse.session_settings"

echo ""
echo "========== 5. The tags on the ClickHouse side =========="
echo ""
echo "-- system.query_log is flushed every 7.5 s by default; SYSTEM FLUSH LOGS forces it."
"${CH[@]}" -q "SYSTEM FLUSH LOGS"
"${CH[@]}" --format PrettyCompactMonoBlock -q "
    SELECT log_comment, user, type,
           Settings['final'] AS query_final, read_rows, result_rows, substring(query, 1, 60) AS query_head
    FROM   system.query_log
    WHERE  log_comment IN ('retl_demo', 'retl_demo_ro2', 'retl_set_before_load')
      AND  type != 'QueryStart'
      AND  event_date >= yesterday()
      AND  query LIKE '%versions_demo%'
    ORDER  BY event_time_microseconds"

echo ""
echo "==========================================================="
echo " Lab 06 complete. Next: ./07-refresh-full-swap.sh"
echo "==========================================================="
