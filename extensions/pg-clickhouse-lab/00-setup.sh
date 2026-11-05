#!/bin/bash

# pg_clickhouse Lab Setup
# Starts a PostgreSQL 18 container with the pg_clickhouse 0.11.0 extension and pg_cron 1.6.8
# (built locally from postgres/Dockerfile), alongside a ClickHouse 26.9.7.9 container on the same Docker network.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 pg_clickhouse Lab Setup"
echo "=========================="
echo ""

if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Install from https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "❌ Docker is not running. Please start Docker Desktop."
    exit 1
fi

cd "$SCRIPT_DIR"

echo "📦 Pulling ClickHouse 26.9.7.9 and building pg_clickhouse 0.11.0 on PG 18 + pg_cron 1.6.8..."
docker compose pull --ignore-buildable
docker compose build

echo ""
echo "▶️  Starting the stack..."
docker compose up -d

echo ""
echo "⏳ Waiting for both services to become healthy..."
for i in $(seq 1 30); do
    PG_OK=$(docker inspect -f '{{.State.Health.Status}}' pgch-postgres 2>/dev/null || echo "starting")
    CH_OK=$(docker inspect -f '{{.State.Health.Status}}' pgch-clickhouse 2>/dev/null || echo "starting")
    if [ "$PG_OK" = "healthy" ] && [ "$CH_OK" = "healthy" ]; then
        echo "   ✅ postgres:  $PG_OK"
        echo "   ✅ clickhouse: $CH_OK"
        break
    fi
    echo "   ... postgres=$PG_OK  clickhouse=$CH_OK  (attempt $i/30)"
    sleep 2
done

echo ""
echo "📍 Service info"
docker compose ps
echo ""
echo "🔗 ClickHouse version: $(docker exec pgch-clickhouse clickhouse-client -q 'SELECT version()' 2>/dev/null)"
echo "🔗 PostgreSQL version: $(docker exec pgch-postgres psql -U postgres -tAc 'SHOW server_version' 2>/dev/null)"
echo "🔗 pg_clickhouse readiness:"
docker exec pgch-postgres psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS pg_clickhouse" 2>&1
docker exec pgch-postgres psql -U postgres -c "SELECT extname, extversion FROM pg_extension WHERE extname='pg_clickhouse'" 2>&1
echo "🔗 pg_cron available (installed in step 05): $(docker exec pgch-postgres psql -U postgres -tAc "SELECT default_version FROM pg_available_extensions WHERE name='pg_cron'" 2>/dev/null)"
echo ""
echo "🎯 Next steps:"
echo "   cd $SCRIPT_DIR"
echo "   ./01-extension-and-server.sh"
echo "   ./02-import-foreign-schema.sh"
echo "   ./03-pushdown-and-aggregates.sh"
echo "   ./04-raw-query-and-dictionary.sh"
echo "   ./05-pg-cron.sh                     # reverse ETL: 05-09"
echo "   ./06-session-settings-and-tagging.sh"
echo "   ./07-refresh-full-swap.sh"
echo "   ./08-refresh-delta-upsert.sh"
echo "   ./09-query-log-correlation.sh"
echo ""
echo "🔧 Convenience clients:"
echo "   ./psql.sh                  - open psql against the lab postgres"
echo "   ./clickhouse-client.sh     - open clickhouse-client"
echo ""
echo "🧹 Teardown:"
echo "   ./cleanup.sh               - stop and remove everything"
echo ""
echo "✅ pg_clickhouse lab is ready!"
