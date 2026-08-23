#!/usr/bin/env bash
# A local Postgres with pgvector and VectorChord, for rehearsing without a
# cloud service. Everything except the ClickHouse comparison runs against it.
#
#   ./scripts/local-postgres.sh up      # start, print the config.env to use
#   ./scripts/local-postgres.sh down
#
# --shm-size is not optional. Postgres asks for a large shared-memory segment
# during a parallel index build and Docker's 64 MB default is not enough:
#   ERROR: could not resize shared memory segment … No space left on device

set -euo pipefail
NAME=vecsearch-pg
IMAGE=${IMAGE:-tensorchord/vchord-postgres:pg17-v0.4.3}
PORT=${PORT:-55433}

case "${1:-up}" in
up)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --shm-size=2g \
        -e POSTGRES_PASSWORD=vector -p "$PORT:5432" "$IMAGE" >/dev/null
    for _ in $(seq 1 60); do
        docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break
        sleep 1
    done
    docker exec "$NAME" psql -U postgres -tAc \
        "SELECT 'server: ' || current_setting('server_version')"
    cat <<CFG

Put this in config.env:

    PGHOST=host.docker.internal
    PGPORT=$PORT
    PGUSER=postgres
    PGPASSWORD=vector
    PGDATABASE=postgres
    PGSSLMODE=disable

CFG
    ;;
down)
    docker rm -f "$NAME" >/dev/null 2>&1 && echo "removed $NAME" || echo "not running"
    ;;
*)
    echo "usage: $0 [up|down]" >&2; exit 2 ;;
esac
