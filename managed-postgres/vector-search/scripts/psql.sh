#!/usr/bin/env bash
# psql against your Managed Postgres service, in a container.
#
#   ./scripts/psql.sh                            # interactive
#   ./scripts/psql.sh -f /sql/01-schema.sql      # run a file (sql/ is /sql)
#   ./scripts/psql.sh -c 'SELECT count(*) FROM vec.dbpedia'
#
# Output is masked so the hostname does not end up in a screenshot.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_docker
load_config

if [ $# -eq 0 ]; then
    docker run --rm -it \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        -v "$LAB_DIR/sql:/sql:ro" \
        "$PSQL_IMAGE" psql
else
    psql_run "$@" 2>&1 | mask
fi
