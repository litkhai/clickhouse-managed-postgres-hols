#!/bin/bash

echo "==========================================================="
echo " pg_clickhouse Lab 01: Extension + Foreign Server + Mapping "
echo "==========================================================="
echo ""

cat 01-extension-and-server.sql | docker exec -i pgch-postgres psql -U postgres

echo ""
echo "==========================================================="
echo " Lab 01 complete."
echo "==========================================================="
