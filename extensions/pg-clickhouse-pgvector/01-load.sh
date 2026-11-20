#!/bin/bash

# Lab 01 — load a slice of the public Hacker News embeddings dataset into ClickHouse,
# then create the Postgres foreign tables and a local pgvector copy.
# ROWS (default 300100) rows are downloaded once into hn_raw; a re-run reuses them.
# The dataset is one 59 GB Parquet file in a public S3 bucket (us-east-1); ClickHouse reads only the
# row groups it needs, but a slice still takes minutes (about 12 minutes for 300k rows from Seoul, 2026-11-20).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ROWS="${ROWS:-300100}"
URL="https://clickhouse-datasets.s3.amazonaws.com/hackernews-miniLM/hackernews_part_1_of_1.parquet"
CH="docker exec -i pgvec-clickhouse clickhouse-client"

echo "==========================================================="
echo " pg_clickhouse pgvector lab 01: load embeddings             "
echo "==========================================================="

$CH -q "CREATE TABLE IF NOT EXISTS hn_raw (id Int32, type Int8, by String, time DateTime64(3, 'UTC'), title String, text String, vector Array(Float32)) ENGINE = MergeTree ORDER BY id"
HAVE=$($CH -q "SELECT count() FROM hn_raw")
if [ "$HAVE" -ge "$ROWS" ]; then
    echo "hn_raw already has $HAVE rows (>= $ROWS): skipping the download."
else
    echo "Downloading $ROWS rows into hn_raw (one time)..."
    $CH -q "TRUNCATE TABLE hn_raw"
    time $CH -q "INSERT INTO hn_raw SELECT id, type, by, time, title, text, vector FROM s3('$URL', NOSIGN) WHERE length(vector) = 384 LIMIT $ROWS"
fi

echo ""
echo "ClickHouse: documents, queries, HNSW index, ground truth..."
time $CH --multiquery < 01-load-clickhouse.sql

echo ""
echo "Postgres: foreign tables and a local pgvector copy with an HNSW index..."
docker exec -i pgvec-postgres psql -U postgres -X -v ON_ERROR_STOP=1 < 01-postgres-objects.sql

echo ""
echo "==========================================================="
echo " Lab 01 complete. Next: ./02-pushdown-shapes.sh"
echo "==========================================================="
