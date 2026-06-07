#!/bin/bash

echo "==========================================================="
echo " pg_clickhouse Lab 04: clickhouse_raw_query + Dictionaries "
echo "==========================================================="
echo ""

cat 04-raw-query-and-dictionary.sql | docker exec -i pgch-postgres psql -U postgres

echo ""
echo "==========================================================="
echo " Lab 04 complete."
echo "==========================================================="
