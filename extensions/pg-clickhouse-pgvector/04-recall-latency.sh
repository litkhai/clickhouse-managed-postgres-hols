#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==========================================================="
echo " pg_clickhouse pgvector lab 04: recall and latency           "
echo "==========================================================="
echo ""

docker exec -i pgvec-postgres psql -U postgres -X < 04-recall-latency.sql

echo ""
echo "==========================================================="
echo " Lab 04 complete."
echo "==========================================================="
