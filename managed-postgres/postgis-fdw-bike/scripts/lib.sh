# Shared connection handling. Sourced, not executed.
#
# psql runs in a container so nothing has to be installed on the host, and the
# password is passed as an environment variable rather than on the command
# line, keeping it out of `ps` and out of shell history.

# BASH_SOURCE is empty when this is sourced from zsh, and `dirname ""` is "."
# — which silently resolves one directory too high. Check the answer instead of
# trusting it.
_lib_self="${BASH_SOURCE[0]:-$0}"
LAB_DIR="$(cd "$(dirname "$_lib_self")/.." 2>/dev/null && pwd)"
if [ -z "$LAB_DIR" ] || [ ! -f "$LAB_DIR/scripts/lib.sh" ]; then
    echo "lib.sh: cannot locate the lab directory from '$_lib_self'." >&2
    echo "Run the scripts directly (./scripts/<name>.sh) rather than sourcing" >&2
    echo "this file from an interactive shell." >&2
    return 1 2>/dev/null || exit 1
fi
unset _lib_self
CONFIG_FILE="$LAB_DIR/config.env"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:17-alpine}"

[ -f "$CONFIG_FILE" ] || {
    echo "no config.env in $LAB_DIR" >&2
    echo "copy config.env.example and fill in your service, or symlink the one" >&2
    echo "from ../provisioning if you already set that up:" >&2
    echo "    ln -s ../provisioning/config.env $LAB_DIR/config.env" >&2
    exit 1
}
set -a; . "$CONFIG_FILE"; set +a
: "${PGHOST:?set PGHOST in config.env}" "${PGPASSWORD:?set PGPASSWORD in config.env}"
: "${PGUSER:=postgres}" "${PGPORT:=5432}" "${PGDATABASE:=postgres}" "${PGSSLMODE:=require}"
export PGUSER PGPORT PGDATABASE PGSSLMODE

# The hostname carries the service name and id; never print it whole.
mask_host() { printf '%s' "$PGHOST" | sed -E 's/^[^.]*\./<service>./; s/\.[a-z0-9]{16,}\./.<id>./'; }

# Run SQL given as an argument.
psql_c() {
    docker run --rm -i \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        "$PSQL_IMAGE" psql -X -q -v ON_ERROR_STOP=1 "$@"
}

# Run SQL, or stream data, from stdin.
psql_stdin() {
    docker run --rm -i \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        "$PSQL_IMAGE" psql -X -q -v ON_ERROR_STOP=1 "$@"
}
