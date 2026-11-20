#!/bin/bash
# Open an interactive clickhouse-client session against the lab ClickHouse
exec docker exec -it pgvec-clickhouse clickhouse-client "$@"
