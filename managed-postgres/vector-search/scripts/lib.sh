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
# terminals. Mask it on the way out.
mask() {
    sed -E "s/${PGHOST//./\\.}/<your-service>.pg.clickhouse.cloud/g"
}

psql_run() {
    docker run --rm -i \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        -v "$LAB_DIR/sql:/sql:ro" \
        "$PSQL_IMAGE" psql "$@"
}

require_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo "Docker is not running. Start Docker Desktop and try again." >&2
        exit 1
    fi
}
