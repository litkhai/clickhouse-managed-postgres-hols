#!/bin/bash

# pg_clickhouse pgvector lab setup
# Starts PostgreSQL 18 with pg_clickhouse 0.11.1 and pgvector 0.8.7 (built locally from postgres/Dockerfile)
# next to ClickHouse 26.9.7.9 on one Docker network.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! docker info &> /dev/null; then
    echo "Docker is not running. Start Docker Desktop (or the Docker daemon) first."
    exit 1
fi

echo "Pulling ClickHouse 26.9.7.9 and building PostgreSQL 18 + pg_clickhouse 0.11.1 + pgvector 0.8.7..."
docker compose pull --ignore-buildable
docker compose build

echo ""
echo "Starting the stack..."
docker compose up -d

echo ""
echo "Waiting for both services to become healthy..."
for i in $(seq 1 30); do
    PG_OK=$(docker inspect -f '{{.State.Health.Status}}' pgvec-postgres 2>/dev/null || echo "starting")
    CH_OK=$(docker inspect -f '{{.State.Health.Status}}' pgvec-clickhouse 2>/dev/null || echo "starting")
    if [ "$PG_OK" = "healthy" ] && [ "$CH_OK" = "healthy" ]; then
        echo "   postgres:   $PG_OK"
        echo "   clickhouse: $CH_OK"
        break
    fi
    echo "   ... postgres=$PG_OK  clickhouse=$CH_OK  (attempt $i/30)"
    sleep 2
done

echo ""
docker compose ps
echo ""
echo "ClickHouse version: $(docker exec pgvec-clickhouse clickhouse-client -q 'SELECT version()')"
echo "PostgreSQL version: $(docker exec pgvec-postgres psql -U postgres -tAc 'SHOW server_version')"
docker exec pgvec-postgres psql -U postgres -X -c "CREATE EXTENSION IF NOT EXISTS vector" -c "CREATE EXTENSION IF NOT EXISTS pg_clickhouse" \
    -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('vector', 'pg_clickhouse') ORDER BY 1"
echo "pg_clickhouse library: $(docker exec pgvec-postgres psql -U postgres -tAc "SELECT pgch_version()" 2>/dev/null || echo 'see CHANGELOG of the image')"
echo ""
echo "Next: ./01-load.sh"
