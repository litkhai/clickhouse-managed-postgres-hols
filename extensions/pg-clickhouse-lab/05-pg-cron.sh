#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==========================================================="
echo " pg_clickhouse Lab 05: pg_cron + the ClickHouse source      "
echo "==========================================================="
echo ""

echo "📦 Package versions inside pgch-postgres:"
docker exec pgch-postgres dpkg-query -W -f='   ${Package} ${Version}\n' "postgresql-18" "postgresql-18-cron"
echo ""

echo "🌱 Seeding ClickHouse (database retl)..."
docker exec -i pgch-clickhouse clickhouse-client -n < 05-seed-clickhouse.sql
echo ""

docker exec -i pgch-postgres psql -U postgres -X < 05-pg-cron.sql

echo ""
echo "==========================================================="
echo " Lab 05 complete."
echo "==========================================================="
