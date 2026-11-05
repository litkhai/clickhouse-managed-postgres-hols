#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==========================================================="
echo " pg_clickhouse Lab 09: pg_cron runs and system.query_log    "
echo "==========================================================="
echo ""

docker exec -i pgch-postgres psql -U postgres -X < 09-query-log-correlation.sql

echo ""
echo "==========================================================="
echo " Lab 09 complete."
echo "==========================================================="
