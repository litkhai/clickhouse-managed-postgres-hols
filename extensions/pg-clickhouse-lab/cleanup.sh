#!/bin/bash
# Stop and remove all containers, networks, and volumes for this lab

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🧹 Tearing down pg_clickhouse lab..."
cd "$SCRIPT_DIR"
docker compose down -v
echo "✅ All containers and networks removed."
