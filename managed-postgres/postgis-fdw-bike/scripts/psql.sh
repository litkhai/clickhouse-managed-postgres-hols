#!/usr/bin/env bash
# psql against the lab's service, with the connection details from config.env.
#
#   ./scripts/psql.sh -f sql/02-verify.sql
#   ./scripts/psql.sh -c 'SELECT count(*) FROM bike.trips'
#   ./scripts/psql.sh                      # interactive
#
# Everything runs in a container, so psql does not have to be installed.
#
# Output is masked (mask_stream in lib.sh) so the hostname and the resolved
# address do not end up in a screenshot, which psql prints in its own connection
# errors. The one exception is an interactive session: a terminal needs -t, and
# a pty merges the two streams, so that session is left as psql prints it.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"

# -i -t so an interactive session gets a terminal; -v mounts the SQL so `-f`
# paths work as written from the lab directory.
if [ $# -eq 0 ] && [ -t 0 ]; then
    exec docker run --rm -i -t \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        -v "$LAB_DIR/sql:/sql:ro" \
        -w / \
        "$PSQL_IMAGE" psql -X -v ON_ERROR_STOP=1
fi

# No -t here even when stdin is a terminal (`psql.sh -c ...` typed by hand): a
# pty would merge stderr into stdout and the two could no longer be masked
# separately. stderr stays on stderr, and with pipefail the exit status is
# psql's, not sed's.
with_masked_stderr docker run --rm -i \
    -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
    -v "$LAB_DIR/sql:/sql:ro" \
    -w / \
    "$PSQL_IMAGE" psql -X -v ON_ERROR_STOP=1 "$@" | mask_stream
