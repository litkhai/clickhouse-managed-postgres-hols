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

# mask_host only covers the lines these scripts echo themselves. psql and libpq
# print the hostname and the resolved address on their own when a connection
# fails:
#   connection to server at "<host>" (10.0.0.1), port 5432 failed: ...
# so anything psql wrote goes through this on the way out. The pattern is the
# literal $PGHOST, dots escaped so they do not match any character. `#` is the
# sed delimiter because a hostname never contains one; the replacement escapes
# the three characters that mean something there. Plain `sed -E` with no GNU or
# BSD extensions, so it runs the same on macOS and Linux. An IPv6 address is
# matched only in its compressed form (it has `::`) or its full eight groups,
# so a time such as (12:30:45) is left alone.
mask_stream() {
    local host_re repl v4 v6
    host_re=$(printf '%s' "$PGHOST" | sed 's/[][\.*^$+?(){}|#]/\\&/g')
    repl=$(mask_host | sed 's/[\&#]/\\&/g')
    v4='([0-9]{1,3}\.){3}[0-9]{1,3}'
    v6='[0-9a-fA-F:]*::[0-9a-fA-F:]*|([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}'
    sed -E "s#${host_re}#${repl}#g; s#\((${v4}|${v6})\)#(<ip>)#g"
}

# Run a command with its stderr masked and its stdout untouched, keeping the
# exit status of the command itself. The scripts parse stdout with `read`, so
# the two streams must stay apart: stderr goes down the pipe, stdout is parked
# on fd 3 for the duration and put back on the other side. pipefail is set in
# the subshell so the status is the command's whatever the caller has set.
with_masked_stderr() {
    ( set -o pipefail; "$@" 2>&1 1>&3 3>&- | mask_stream >&2 ) 3>&1
}

# Run SQL given as an argument.
psql_c() {
    with_masked_stderr docker run --rm -i \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        "$PSQL_IMAGE" psql -X -q -v ON_ERROR_STOP=1 "$@"
}

# Run SQL, or stream data, from stdin.
psql_stdin() {
    with_masked_stderr docker run --rm -i \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        "$PSQL_IMAGE" psql -X -q -v ON_ERROR_STOP=1 "$@"
}
