#!/usr/bin/env bash
# psql against the lab's service, with the connection details from config.env.
#
#   ./scripts/psql.sh -f sql/02-verify.sql
#   ./scripts/psql.sh -c 'SELECT count(*) FROM bike.trips'
#   ./scripts/psql.sh                      # interactive
#
# Everything runs in a container, so psql does not have to be installed.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"

# -i -t so an interactive session gets a terminal; -v mounts the SQL so `-f`
# paths work as written from the lab directory.
exec docker run --rm -i $([ -t 0 ] && echo -t) \
    -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
    -v "$LAB_DIR/sql:/sql:ro" \
    -w / \
    "$PSQL_IMAGE" psql -X -v ON_ERROR_STOP=1 "$@"
