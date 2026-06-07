#!/bin/bash

echo "==========================================================="
echo " pg_clickhouse Lab 02: Seed CH data + IMPORT FOREIGN SCHEMA "
echo "==========================================================="
echo ""

echo "▶︎ Seeding ClickHouse with lab.events and lab.users..."
docker exec -i pgch-clickhouse clickhouse-client --multiquery < 02-seed-clickhouse.sql

echo ""
echo "▶︎ Importing schema into PostgreSQL..."
cat 02-import-foreign-schema.sql | docker exec -i pgch-postgres psql -U postgres

echo ""
echo "==========================================================="
echo " Lab 02 complete."
echo "==========================================================="
