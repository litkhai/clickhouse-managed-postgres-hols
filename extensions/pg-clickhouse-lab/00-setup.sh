#!/bin/bash

# pg_clickhouse Lab Setup
# Starts a PostgreSQL 18 container preloaded with the pg_clickhouse extension,
# alongside a ClickHouse 26.5 container on the same Docker network.

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

echo "📦 Pulling images (clickhouse 26.5 + pg_clickhouse 18)..."
docker compose pull

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
echo ""
echo "🎯 Next steps:"
echo "   cd $SCRIPT_DIR"
echo "   ./01-extension-and-server.sh"
echo "   ./02-import-foreign-schema.sh"
echo "   ./03-pushdown-and-aggregates.sh"
echo "   ./04-raw-query-and-dictionary.sh"
echo ""
echo "🔧 Convenience clients:"
echo "   ./psql.sh                  - open psql against the lab postgres"
echo "   ./clickhouse-client.sh     - open clickhouse-client"
echo ""
echo "🧹 Teardown:"
echo "   ./cleanup.sh               - stop and remove everything"
echo ""
echo "✅ pg_clickhouse lab is ready!"
