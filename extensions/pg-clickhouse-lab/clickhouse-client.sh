#!/bin/bash
# Open an interactive clickhouse-client session against the lab ClickHouse
exec docker exec -it pgch-clickhouse clickhouse-client "$@"
