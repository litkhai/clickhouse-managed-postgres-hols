#!/usr/bin/env bash
# Connect to a ClickHouse Managed Postgres service and report what answered.
#
#   cp config.env.example config.env   # fill in your own service
#   ./01-connect-test.sh
#
# psql runs in a container so nothing has to be installed on the host, matching
# how the rest of this repository works. Credentials are passed as environment
# variables rather than on the command line, so they stay out of `ps` output and
# out of the container's shell history.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
CONFIG_FILE="config.env"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:17-alpine}"

[ -f "$CONFIG_FILE" ] || {
    echo "no $CONFIG_FILE — copy config.env.example and fill in your service" >&2
    exit 1
}
set -a; . "./$CONFIG_FILE"; set +a
: "${PGHOST:?set PGHOST in $CONFIG_FILE}"
: "${PGPASSWORD:?set PGPASSWORD in $CONFIG_FILE}"
: "${PGUSER:=postgres}" "${PGPORT:=5432}" "${PGDATABASE:=postgres}" "${PGSSLMODE:=require}"
export PGUSER PGPORT PGDATABASE PGSSLMODE

# The hostname embeds the service name and id, so only ever show it masked.
mask() { sed -E 's/^[^.]*\./<service>./; s/\.[a-z0-9]{16,}\./.<id>./'; }

psql_q() {
    docker run --rm -i \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        "$PSQL_IMAGE" psql -X -A -F' | ' -q -v ON_ERROR_STOP=1 -c "$1"
}

echo "host    : $(printf '%s' "$PGHOST" | mask)"
echo "port    : $PGPORT   user: $PGUSER   sslmode: $PGSSLMODE"
echo

echo "── server ─────────────────────────────────────────"
psql_q "
SELECT 'version'      AS key, current_setting('server_version')       AS value
UNION ALL SELECT 'user',        current_user
UNION ALL SELECT 'database',    current_database()
UNION ALL SELECT 'superuser',   current_setting('is_superuser')
UNION ALL SELECT 'read_only',   pg_is_in_recovery()::text
UNION ALL SELECT 'tls',         (SELECT COALESCE(version, 'none') FROM pg_stat_ssl WHERE pid = pg_backend_pid())
UNION ALL SELECT 'wal_level',   current_setting('wal_level')
UNION ALL SELECT 'max_conns',   current_setting('max_connections');"

echo
echo "── extensions ─────────────────────────────────────"
psql_q "
SELECT e.name AS extension,
       e.default_version AS available,
       COALESCE(i.extversion, '-') AS installed
FROM pg_available_extensions e
LEFT JOIN pg_extension i ON i.extname = e.name
WHERE i.extname IS NOT NULL OR e.name ILIKE '%clickhouse%'
ORDER BY 1;"

echo
echo "── round trip ─────────────────────────────────────"
# Prove writes work, not just that the handshake succeeded. A temp table is
# dropped with the session, so the service is left exactly as it was found.
psql_q "
CREATE TEMP TABLE connect_check (id int, note text);
INSERT INTO connect_check VALUES (1, 'write'), (2, 'read');
SELECT count(*)::text || ' rows written and read back' AS result FROM connect_check;"

echo
echo "OK: connected, queried and wrote."
