#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==========================================================="
echo " pg_clickhouse pgvector lab 02: pushdown and index use      "
echo "==========================================================="
echo ""

docker exec -i pgvec-postgres psql -U postgres -X < 02-pushdown-shapes.sql

echo ""
echo "==========================================================="
echo " Lab 02 complete."
echo "==========================================================="
