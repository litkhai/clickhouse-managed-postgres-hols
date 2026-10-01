#!/usr/bin/env bash
# Create a ClickHouse Managed Postgres service through the Cloud API, wait until
# it is running, and write its connection details to ./config.env.
#
#   ./00-create-service.sh --dry-run        # print the request body, send nothing
#   ./00-create-service.sh                  # ask, create, wait
#   ./00-create-service.sh --yes --name "my lab" --region us-east-1 --size r6gd.medium
#
#   ./00-create-service.sh [--name NAME] [--region REGION] [--size SIZE]
#                          [--pg 18|17] [--ha none|async|sync] [--dry-run] [--yes]
#
# Defaults: name "mpg hols", region ap-northeast-2, size m6gd.large, pg 18, ha none.
#
# THIS COSTS MONEY from the moment the call succeeds until 99-delete-service.sh
# removes the service.
#
# Credentials: CHC_ORG_ID, CHC_KEY_ID and CHC_KEY_SECRET, taken from the
# environment; for any that are missing, from the file named by CHC_ENV_FILE, or
# else from ./config.env. --dry-run needs none of them.
#
# The create response carries the superuser password. It goes straight into a
# mode-600 config.env and is never printed. The API secret goes to curl on stdin
# (-K -), so neither secret appears in `ps`.
#
# Knobs for tests and slow regions:
#   CHC_API_URL      default https://api.clickhouse.cloud
#   POLL_SECONDS     default 15
#   TIMEOUT_SECONDS  default 1800
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
cd "$SCRIPT_DIR"
umask 077

CONFIG_FILE="config.env"
API_URL="${CHC_API_URL:-https://api.clickhouse.cloud}"
API_URL="${API_URL%/}"
POLL_SECONDS="${POLL_SECONDS:-15}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"

NAME="mpg hols"
PROVIDER="aws"
REGION="ap-northeast-2"
SIZE="m6gd.large"
PG_VERSION="18"
HA="none"
DRY_RUN=0
ASSUME_YES=0

usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; }
die()   { echo "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --name|--region|--size|--pg|--ha)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in
                --name)   NAME="$2" ;;
                --region) REGION="$2" ;;
                --size)   SIZE="$2" ;;
                --pg)     PG_VERSION="$2" ;;
                --ha)     HA="$2" ;;
            esac
            shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes)     ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "unknown argument: $1" ;;
    esac
done

case "$PG_VERSION" in 18|17) ;; *) die "--pg must be 18 or 17" ;; esac
case "$HA" in none|async|sync) ;; *) die "--ha must be none, async or sync" ;; esac

# The hostname embeds the service name and id, so only ever show it masked.
mask() { sed -E 's/^[^.]*\./<service>./; s/\.[a-z0-9]{16,}\./.<id>./'; }

# --- 1. the request body (holds no secret) ---------------------------------
BODY=$(python3 - "$NAME" "$PROVIDER" "$REGION" "$SIZE" "$PG_VERSION" "$HA" <<'PY'
import json, sys
name, provider, region, size, pg, ha = sys.argv[1:7]
print(json.dumps({"name": name, "provider": provider, "region": region,
                  "size": size, "postgresVersion": pg, "haType": ha}))
PY
)

echo "POST $API_URL/v1/organizations/<org-id>/postgres"
printf '%s\n' "$BODY" | python3 -m json.tool

# --- 2. dry run stops here -------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "dry run: nothing was sent."
    exit 0
fi

# --- 3. credentials ---------------------------------------------------------
# Environment first; for what is missing, CHC_ENV_FILE, else ./config.env. Each
# value is read in a subshell so the rest of that file never enters this shell.
value_from_file() {   # NAME FILE -> prints the value; fails if the file does not set it
    ( set +u; . "$2" >/dev/null 2>&1 || true
      [ -n "${!1:-}" ] || exit 1
      printf '%s' "${!1}" )
}
CREDS_FILE="${CHC_ENV_FILE:-./$CONFIG_FILE}"
case "$CREDS_FILE" in */*) ;; *) CREDS_FILE="./$CREDS_FILE" ;; esac
MISSING=()
for v in CHC_ORG_ID CHC_KEY_ID CHC_KEY_SECRET; do
    if [ -z "${!v:-}" ] && [ -f "$CREDS_FILE" ]; then
        if val=$(value_from_file "$v" "$CREDS_FILE"); then export "$v=$val"; fi
    fi
    [ -n "${!v:-}" ] || MISSING+=("$v")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo >&2
    echo "missing: ${MISSING[*]}" >&2
    echo "set them in the environment, or in the file named by CHC_ENV_FILE, or in ./$CONFIG_FILE" >&2
    echo "(see config.env.example). No request was made." >&2
    exit 1
fi

# --- 4. never orphan a billed service --------------------------------------
if [ -f "$CONFIG_FILE" ] && value_from_file PG_SERVICE_ID "$CONFIG_FILE" >/dev/null; then
    echo >&2
    echo "refusing: ./$CONFIG_FILE already has PG_SERVICE_ID set." >&2
    echo "Creating another service would overwrite it and orphan a live, billed one." >&2
    echo "Delete that one first with ./99-delete-service.sh, or remove the PG_SERVICE_ID" >&2
    echo "line if you know that service is already gone." >&2
    exit 1
fi

# --- 5. confirm -------------------------------------------------------------
if [ "$ASSUME_YES" -ne 1 ]; then
    printf '\nCreate this service? It is billed from now until it is deleted. [y/N] '
    ANSWER=""
    read -r ANSWER || true
    case "$ANSWER" in y|Y) ;; *) echo "not created."; exit 0 ;; esac
fi

# --- helpers for the calls --------------------------------------------------
RESP=""; POLL_RESP=""
trap 'rm -f "$RESP" "$POLL_RESP"' EXIT
RESP=$(mktemp)
POLL_RESP=$(mktemp)

# curl reads its basic-auth user from stdin (-K -): printf is a builtin, so the
# secret never becomes an argument of any process.
esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
chc_curl() {   # METHOD URL OUTFILE [BODY]  -> prints the HTTP status
    local method=$1 url=$2 out=$3 body=${4-}
    local args=(-sS --connect-timeout 10 --max-time 60 -K - -X "$method" -o "$out" -w '%{http_code}')
    [ -z "$body" ] || args+=(-H 'Content-Type: application/json' -d "$body")
    printf 'user = "%s:%s"\n' "$(esc "$CHC_KEY_ID")" "$(esc "$CHC_KEY_SECRET")" | curl "${args[@]}" "$url"
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

ts() { date -u +%H:%M:%SZ; }

report_http_error() {   # STATUS FILE
    echo "HTTP $1: $(json_field "$2" error)" >&2
}

# --- the create call --------------------------------------------------------
echo
echo "$(ts) creating ..."
STATUS=$(chc_curl POST "$API_URL/v1/organizations/$CHC_ORG_ID/postgres" "$RESP" "$BODY") \
    || die "request failed: could not reach $API_URL"
case "$STATUS" in
    2??) ;;
    *) report_http_error "$STATUS" "$RESP"; exit 1 ;;
esac

# The response holds the password. Write ./config.env before anything else can
# fail, then delete the response. Nothing below prints a value from it except
# the non-secret fields returned on stdout.
FIELDS=$(python3 - "$RESP" "$CONFIG_FILE" <<'PY'
import json, os, re, shlex, sys, time
resp_path, out_path = sys.argv[1:3]
try:
    result = json.load(open(resp_path))["result"]
    host, user, password, pgid = (result[k] for k in ("hostname", "username", "password", "id"))
except Exception as e:
    sys.exit("the response did not have result.id/hostname/username/password (%s); "
             "check the console for a service you did not mean to create" % type(e).__name__)

# Keep API credentials that already lived in config.env, so 99-delete-service.sh
# can still find them after this file is rewritten.
kept = []
if os.path.exists(out_path):
    pat = re.compile(r"^\s*(export\s+)?CHC_(ORG_ID|KEY_ID|KEY_SECRET)=")
    kept = [l.rstrip("\n") for l in open(out_path) if pat.match(l)]

lines = [
    "# Written by 00-create-service.sh on %s." % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "# Gitignored; it holds the superuser password. Mode 600. Remove the service with",
    "# ./99-delete-service.sh before you discard this file.",
    "PGHOST=%s" % shlex.quote(host),
    "PGPORT=5432",
    "PGUSER=%s" % shlex.quote(user),
    "PGPASSWORD=%s" % shlex.quote(password),
    "PGDATABASE=postgres",
    "PGSSLMODE=require",
    "PG_SERVICE_ID=%s" % shlex.quote(pgid),
]
if kept:
    lines += ["", "# kept from the previous config.env"] + kept

tmp = "%s.tmp.%d" % (out_path, os.getpid())
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(lines) + "\n")
os.replace(tmp, out_path)
os.chmod(out_path, 0o600)

print("|".join(str(result.get(k, "")) for k in ("hostname", "state", "region", "size", "postgresVersion")))
PY
) || { rm -f "$RESP"; exit 1; }
rm -f "$RESP"
IFS='|' read -r HOST STATE REGION_OUT SIZE_OUT PGV <<< "$FIELDS"
SERVICE_ID=$(value_from_file PG_SERVICE_ID "$CONFIG_FILE")

echo "$(ts) created: <id>   (connection details written to ./$CONFIG_FILE, mode 600)"
echo "$(ts) state: ${STATE:-unknown}"

# --- wait for running -------------------------------------------------------
# A transport error or a 5xx while waiting is retried; a 4xx will not recover.
LAST="${STATE:-}"
DEADLINE=$(( SECONDS + TIMEOUT_SECONDS ))
while :; do
    if STATUS=$(chc_curl GET "$API_URL/v1/organizations/$CHC_ORG_ID/postgres/$SERVICE_ID" "$POLL_RESP"); then
        case "$STATUS" in
            2??)
                NOW=$(json_field "$POLL_RESP" result.state)
                if [ "$NOW" != "$LAST" ]; then echo "$(ts) state: $NOW"; LAST=$NOW; fi
                if [ "$NOW" = "running" ]; then break; fi
                ;;
            5??) echo "$(ts) poll: HTTP $STATUS, will retry" ;;
            *)   report_http_error "$STATUS" "$POLL_RESP"
                 echo "the service may still exist; ./$CONFIG_FILE is kept so ./99-delete-service.sh can remove it." >&2
                 exit 1 ;;
        esac
    else
        echo "$(ts) poll: could not reach $API_URL, will retry"
    fi
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
        echo "timed out after ${TIMEOUT_SECONDS}s waiting for state=running (last: ${LAST:-unknown})." >&2
        echo "./$CONFIG_FILE is kept, so ./99-delete-service.sh can still remove the service." >&2
        exit 1
    fi
    sleep "$POLL_SECONDS"
done

echo
echo "host    : $(printf '%s' "$HOST" | mask)"
echo "state   : $LAST"
echo "region  : ${REGION_OUT:-$REGION}"
echo "size    : ${SIZE_OUT:-$SIZE}"
echo "pg      : ${PGV:-$PG_VERSION}"
echo "id      : <id>   (PG_SERVICE_ID in ./$CONFIG_FILE)"
echo
echo "next: ./01-connect-test.sh"
