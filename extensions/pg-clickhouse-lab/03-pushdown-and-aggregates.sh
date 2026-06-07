#!/bin/bash

echo "==========================================================="
echo " pg_clickhouse Lab 03: Pushdown — JOIN, GROUP BY, Window   "
echo "==========================================================="
echo ""

cat 03-pushdown-and-aggregates.sql | docker exec -i pgch-postgres psql -U postgres

echo ""
echo "==========================================================="
echo " Lab 03 complete."
echo "==========================================================="
