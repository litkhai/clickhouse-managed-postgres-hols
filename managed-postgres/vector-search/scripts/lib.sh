#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export LAB_DIR

# Only a client is needed: pgvector and vchord live on the server. The plain
# postgres image is multi-arch, where the pgvector-bundled images are not
# always built for arm64.
PSQL_IMAGE="${PSQL_IMAGE:-postgres:17-alpine}"

load_config() {
    if [ -f "$LAB_DIR/config.env" ]; then
        # shellcheck disable=SC1091
        set -a; . "$LAB_DIR/config.env"; set +a
    fi
    local missing=()
    [ -n "${PGHOST:-}" ]     || missing+=(PGHOST)
    [ -n "${PGPASSWORD:-}" ] || missing+=(PGPASSWORD)
    if [ ${#missing[@]} -gt 0 ]; then
        cat >&2 <<EOF
missing: ${missing[*]}

    cp config.env.example config.env
    \$EDITOR config.env

config.env is gitignored. This repository is public — never commit real
endpoints or passwords.
EOF
        exit 1
    fi
    export PGHOST PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" \
           PGPASSWORD PGDATABASE="${PGDATABASE:-postgres}" \
           PGSSLMODE="${PGSSLMODE:-require}"
}

# The hostname carries the service name and id, and people screenshot their
# terminals. Mask it on the way out: the Postgres host always, and the ClickHouse
# host when CH_HOST is set.
mask() {
    local expr=""
    if [ -n "${PGHOST:-}" ]; then
        expr="s/${PGHOST//./\\.}/<your-service>.pg.clickhouse.cloud/g"
    fi
    if [ -n "${CH_HOST:-}" ]; then
        expr="${expr:+$expr;}s/${CH_HOST//./\\.}/<your-service>.clickhouse.cloud/g"
    fi
    if [ -n "$expr" ]; then sed -E "$expr"; else cat; fi
}

# The CH_* variables are passed by name only (-e NAME, no =value), so the
# ClickHouse password never appears in the docker command line or in `ps`.
# sql/_clickhouse-vars.sql reads them with \getenv.
psql_run() {
    docker run --rm -i \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        -e CH_HOST -e CH_PORT -e CH_USER -e CH_PASSWORD -e CH_DATABASE \
        -v "$LAB_DIR/sql:/sql:ro" \
        "$PSQL_IMAGE" psql "$@"
}

require_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo "Docker is not running. Start Docker Desktop and try again." >&2
        exit 1
    fi
}
