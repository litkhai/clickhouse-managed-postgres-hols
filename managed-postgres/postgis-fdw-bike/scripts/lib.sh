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

# config.env is sourced over the environment, so a PG* value in the file wins. The
# ClickHouse side is the other way round: CH_DATABASE=other ./scripts/teardown.sh
# has to mean `other`, so a CH_* or CHC_* value already in the environment is put
# back after the file is read. The CHC_* API credentials are not taken from the
# file at all here — chc_load reads them one at a time, when a script that calls
# the API asks — so the key secret does not sit in the environment of every
# docker and psql this lab starts.
_env_keep=()
for _v in CH_HOST CH_PORT CH_USER CH_PASSWORD CH_DATABASE CH_SECURE \
          CHC_ORG_ID CHC_KEY_ID CHC_KEY_SECRET CHC_SERVICE_ID; do
    if [ -n "${!_v+set}" ]; then _env_keep+=("$_v=${!_v}"); fi
done
set -a; . "$CONFIG_FILE"; set +a
unset CHC_ORG_ID CHC_KEY_ID CHC_KEY_SECRET CHC_SERVICE_ID
for _kv in ${_env_keep[@]+"${_env_keep[@]}"}; do export "${_kv%%=*}=${_kv#*=}"; done
unset _env_keep _v _kv
: "${PGHOST:?set PGHOST in config.env}" "${PGPASSWORD:?set PGPASSWORD in config.env}"
: "${PGUSER:=postgres}" "${PGPORT:=5432}" "${PGDATABASE:=postgres}" "${PGSSLMODE:=require}"
export PGUSER PGPORT PGDATABASE PGSSLMODE

# The hostname carries the service name and id; never print it whole. Without an
# argument it is the Postgres host; the ClickHouse host (<service>.<region>.aws.
# clickhouse.cloud) goes through the same filter.
mask_host() { printf '%s' "${1:-$PGHOST}" | sed -E 's/^[^.]*\./<service>./; s/\.[a-z0-9]{16,}\./.<id>./'; }

# One `s#host#masked#g;` expression for a host: the pattern is the literal host,
# dots escaped so they do not match any character. `#` is the sed delimiter
# because a hostname never contains one; the replacement escapes the three
# characters that mean something there.
_mask_expr() {
    local host_re repl
    host_re=$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|#]/\\&/g')
    repl=$(mask_host "$1" | sed 's/[\&#]/\\&/g')
    printf 's#%s#%s#g;' "$host_re" "$repl"
}

# mask_host only covers the lines these scripts echo themselves. psql and libpq
# print the hostname and the resolved address on their own when a connection
# fails:
#   connection to server at "<host>" (10.0.0.1), port 5432 failed: ...
# so anything psql wrote goes through this on the way out — the Postgres host,
# and CH_HOST when the ClickHouse side is in use (clickhouse-client and the
# foreign-server errors name it too). Plain `sed -E` with no GNU or BSD
# extensions, so it runs the same on macOS and Linux. An IPv6 address is
# matched only in its compressed form (it has `::`) or its full eight groups,
# so a time such as (12:30:45) is left alone.
mask_stream() {
    local expr v4 v6
    expr=$(_mask_expr "$PGHOST")
    if [ -n "${CH_HOST:-}" ]; then expr="$expr$(_mask_expr "$CH_HOST")"; fi
    v4='([0-9]{1,3}\.){3}[0-9]{1,3}'
    v6='[0-9a-fA-F:]*::[0-9a-fA-F:]*|([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}'
    sed -E "${expr} s#\((${v4}|${v6})\)#(<ip>)#g"
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

die() { echo "$*" >&2; exit 1; }

# --- the ClickHouse side -----------------------------------------------------
# For clickpipe.sh and teardown.sh. Nothing here runs when lib.sh is sourced.

# The image is the pin vector-search/scripts/clickhouse.sh uses. Override with CH_IMAGE.
CH_IMAGE="${CH_IMAGE:-clickhouse/clickhouse-server:26.9.7.9@sha256:1f9c29a753cc07f9e2272a9d9383a840b222bbda78166da39dd10eecafe6500d}"

# Databases on a shared service that other work lives in. The lab creates
# CH_DATABASE and teardown.sh drops it, so it must never be one of these.
CH_PROTECTED_DBS="default system pg_sync ny_citibike"

# Fill in the defaults for the optional CH_* values, then refuse a CH_DATABASE
# that is not this lab's own. The name goes straight into backticked SQL, so it
# has to be a plain identifier. This part needs no host or password, so a
# --dry-run can use it.
ch_database_check() {
    : "${CH_PORT:=9440}" "${CH_USER:=default}" "${CH_DATABASE:=mpg_hols_bike}" "${CH_SECURE:=true}"
    export CH_PORT CH_USER CH_DATABASE CH_SECURE
    case "$CH_SECURE" in true|false) ;; *) die "CH_SECURE must be true or false, got: $CH_SECURE" ;; esac
    [[ "$CH_DATABASE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || die "CH_DATABASE must be a plain identifier (letters, digits, underscore), got: $CH_DATABASE"
    local lower p
    lower=$(printf '%s' "$CH_DATABASE" | tr '[:upper:]' '[:lower:]')
    for p in $CH_PROTECTED_DBS; do
        [ "$lower" != "$p" ] || die "refusing: CH_DATABASE=$CH_DATABASE is a shared database ($CH_PROTECTED_DBS).
Use a database of this lab's own, e.g. mpg_hols_bike."
    done
}

# Everything a script needs before it talks to ClickHouse.
ch_init() {
    : "${CH_HOST:?set CH_HOST in config.env}" "${CH_PASSWORD:?set CH_PASSWORD in config.env}"
    ch_database_check
    # clickhouse-client reads its password from CLICKHOUSE_PASSWORD, so it never
    # goes on a command line, where `ps` would show it.
    export CLICKHOUSE_PASSWORD="$CH_PASSWORD"
}

# clickhouse-client against CH_HOST, in a container. Arguments go to the client
# (-q 'SELECT ...'). The password reaches the container by name only (-e NAME,
# no value); stderr is masked because the client names the host in its errors.
ch_client() {
    local secure=(--secure)
    [ "$CH_SECURE" != false ] || secure=()
    with_masked_stderr docker run --rm -i -e CLICKHOUSE_PASSWORD "$CH_IMAGE" \
        clickhouse-client --host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER" \
        ${secure[@]+"${secure[@]}"} "$@"
}

# --- the ClickHouse Cloud API (ClickPipes) -----------------------------------
CHC_API_URL="${CHC_API_URL:-https://api.clickhouse.cloud}"
CHC_API_URL="${CHC_API_URL%/}"

# The one ClickPipe this lab owns. clickpipe.sh and teardown.sh find it by name.
PIPE_NAME="mpg hols bike"

value_from_file() {   # NAME FILE -> prints the value; fails if the file does not set it
    ( set +u; . "$2" >/dev/null 2>&1 || true
      [ -n "${!1:-}" ] || exit 1
      printf '%s' "${!1}" )
}

# CHC_ORG_ID, CHC_KEY_ID, CHC_KEY_SECRET and CHC_SERVICE_ID, the way
# ../provisioning/00-create-service.sh reads its credentials: the environment
# first; for what is missing, the file named by CHC_ENV_FILE; then config.env.
# Each value is read in a subshell, so nothing else in those files enters this
# shell.
chc_load() {
    local v val f missing=()
    for v in CHC_ORG_ID CHC_KEY_ID CHC_KEY_SECRET CHC_SERVICE_ID; do
        for f in ${CHC_ENV_FILE:+"$CHC_ENV_FILE"} "$CONFIG_FILE"; do
            [ -z "${!v:-}" ] || break
            case "$f" in */*) ;; *) f="./$f" ;; esac
            if [ -f "$f" ] && val=$(value_from_file "$v" "$f"); then export "$v=$val"; fi
        done
        [ -n "${!v:-}" ] || missing+=("$v")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "missing: ${missing[*]}" >&2
        echo "set them in the environment, or in the file named by CHC_ENV_FILE, or in config.env" >&2
        echo "(see config.env.example; CHC_SERVICE_ID is on the Console's service Settings page)." >&2
        echo "No request was made." >&2
        exit 1
    fi
}

# curl reads its basic-auth user from a config file, here a process substitution
# of the printf builtin: the secret never becomes an argument of any process. The
# JSON body, which holds the Postgres password, goes in on stdin
# (--data-binary @-) for the same reason.
esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
chc_curl() {   # METHOD PATH OUTFILE [BODY] -> prints the HTTP status
    local method=$1 path=$2 out=$3 body=${4-}
    if [ -n "$body" ]; then
        printf '%s' "$body" | curl -sS --connect-timeout 10 --max-time 60 \
            -K <(printf 'user = "%s:%s"\n' "$(esc "$CHC_KEY_ID")" "$(esc "$CHC_KEY_SECRET")") \
            -X "$method" -H 'Content-Type: application/json' --data-binary @- \
            -o "$out" -w '%{http_code}' "$CHC_API_URL$path"
    else
        curl -sS --connect-timeout 10 --max-time 60 \
            -K <(printf 'user = "%s:%s"\n' "$(esc "$CHC_KEY_ID")" "$(esc "$CHC_KEY_SECRET")") \
            -X "$method" -o "$out" -w '%{http_code}' "$CHC_API_URL$path" </dev/null
    fi
}

json_field() {   # FILE dotted.path -> the value, or nothing
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for k in sys.argv[2].split("."):
        d = d[k]
    print(json.dumps(d) if isinstance(d, (dict, list)) else ("" if d is None else d))
except Exception:
    pass
PY
}

chc_pipes_path() { printf '/v1/organizations/%s/services/%s/clickpipes' "$CHC_ORG_ID" "$CHC_SERVICE_ID"; }

# Every pipe with this name, one "id<TAB>state" per line; nothing when there is
# none. Fails, with the API's message, when the list call does.
chc_find_pipes() {   # NAME
    local out status
    out=$(mktemp)
    status=$(chc_curl GET "$(chc_pipes_path)" "$out") || { rm -f "$out"; die "request failed: could not reach $CHC_API_URL"; }
    case "$status" in
        2??) ;;
        *) echo "HTTP $status: $(json_field "$out" error)" >&2; rm -f "$out"; return 1 ;;
    esac
    python3 - "$out" "$1" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1])).get("result") or []:
    if p.get("name") == sys.argv[2]:
        print("%s\t%s" % (p.get("id", ""), p.get("state", "")))
PY
    rm -f "$out"
}

# ClickPipes creates the publication and the replication slot itself when none is
# named, and calls them after the pipe id with every '-' written as '__'. These
# names were read from the two Postgres pipes already running in the org on
# 2026-10-14; the OpenAPI spec does not document them.
PIPE_ID_RE='^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
pipe_slot_name() { printf 'peerflow_slot_mirror_%s' "${1//-/__}"; }
pipe_pub_name()  { printf 'peerflow_pub_mirror_%s' "${1//-/__}"; }
