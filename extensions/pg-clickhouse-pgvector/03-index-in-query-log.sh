#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==========================================================="
echo " pg_clickhouse pgvector lab 03: index use in query_log       "
echo "==========================================================="
echo ""

docker exec -i pgvec-postgres psql -U postgres -X < 03-index-in-query-log.sql

echo ""
echo "==========================================================="
echo " Lab 03 complete."
echo "==========================================================="
