#!/usr/bin/env bash
# Delete the Managed Postgres service named by PG_SERVICE_ID in ./config.env,
# wait until the API says it is gone, then set config.env aside.
#
#   ./99-delete-service.sh            # show it, ask, delete, wait
#   ./99-delete-service.sh --yes      # no question
#
# THIS CANNOT BE UNDONE. The service and everything in it are deleted.
#
# Credentials are resolved exactly as in 00-create-service.sh: CHC_ORG_ID,
# CHC_KEY_ID and CHC_KEY_SECRET from the environment, else CHC_ENV_FILE, else
# ./config.env. The secret goes to curl on stdin, never into argv.
#
# Afterwards config.env is renamed to config.env.deleted-<UTC timestamp> (mode
# 600) rather than removed. It still holds the old password, so delete it when
# you no longer need it.
#
# Knobs: CHC_API_URL (default https://api.clickhouse.cloud), POLL_SECONDS
# (default 15), TIMEOUT_SECONDS (default 900).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
cd "$SCRIPT_DIR"
umask 077

CONFIG_FILE="config.env"
API_URL="${CHC_API_URL:-https://api.clickhouse.cloud}"
API_URL="${API_URL%/}"
POLL_SECONDS="${POLL_SECONDS:-15}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
ASSUME_YES=0

usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; }
die()   { echo "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --yes)     ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "unknown argument: $1" ;;
    esac
done

# The hostname embeds the service name and id, so only ever show it masked.
mask() { sed -E 's/^[^.]*\./<service>./; s/\.[a-z0-9]{16,}\./.<id>./'; }

# --- credentials (same rules as 00-create-service.sh) -----------------------
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
    echo "missing: ${MISSING[*]}" >&2
    echo "set them in the environment, or in the file named by CHC_ENV_FILE, or in ./$CONFIG_FILE" >&2
    echo "(see config.env.example). No request was made." >&2
    exit 1
fi

[ -f "$CONFIG_FILE" ] || die "no ./$CONFIG_FILE, so there is no PG_SERVICE_ID to delete."
PG_SERVICE_ID=$(value_from_file PG_SERVICE_ID "$CONFIG_FILE") \
    || die "PG_SERVICE_ID is not set in ./$CONFIG_FILE; nothing to delete."

# --- helpers ----------------------------------------------------------------
RESP=""
trap 'rm -f "$RESP"' EXIT
RESP=$(mktemp)

# curl reads its basic-auth user from stdin (-K -): printf is a builtin, so the
# secret never becomes an argument of any process.
esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
chc_curl() {   # METHOD URL OUTFILE  -> prints the HTTP status
    local method=$1 url=$2 out=$3
    printf 'user = "%s:%s"\n' "$(esc "$CHC_KEY_ID")" "$(esc "$CHC_KEY_SECRET")" \
        | curl -sS --connect-timeout 10 --max-time 60 -K - -X "$method" -o "$out" -w '%{http_code}' "$url"
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
report_http_error() { echo "HTTP $1: $(json_field "$2" error)" >&2; }
SERVICE_URL="$API_URL/v1/organizations/$CHC_ORG_ID/postgres/$PG_SERVICE_ID"

# --- show what is about to go -----------------------------------------------
STATUS=$(chc_curl GET "$SERVICE_URL" "$RESP") || die "request failed: could not reach $API_URL"
case "$STATUS" in
    2??) ;;
    *) report_http_error "$STATUS" "$RESP"; exit 1 ;;
esac
NAME=$(json_field "$RESP" result.name)
HOST=$(json_field "$RESP" result.hostname)
echo "name    : ${NAME:0:1}***"
[ -z "$HOST" ] || echo "host    : $(printf '%s' "$HOST" | mask)"
echo "state   : $(json_field "$RESP" result.state)"
echo "region  : $(json_field "$RESP" result.region)"
echo "size    : $(json_field "$RESP" result.size)"
echo "id      : <id>   (PG_SERVICE_ID in ./$CONFIG_FILE)"

if [ "$ASSUME_YES" -ne 1 ]; then
    printf '\nDelete this service? This cannot be undone. [y/N] '
    ANSWER=""
    read -r ANSWER || true
    case "$ANSWER" in y|Y) ;; *) echo "not deleted."; exit 0 ;; esac
fi

# --- delete, then wait for 404 ----------------------------------------------
echo
echo "$(ts) deleting ..."
STATUS=$(chc_curl DELETE "$SERVICE_URL" "$RESP") || die "request failed: could not reach $API_URL"
case "$STATUS" in
    2??) ;;
    *) report_http_error "$STATUS" "$RESP"; exit 1 ;;
esac

# A transport error or a 5xx while waiting is retried; any other status that is
# neither 2xx nor 404 will not recover.
LAST=""
DEADLINE=$(( SECONDS + TIMEOUT_SECONDS ))
while :; do
    if STATUS=$(chc_curl GET "$SERVICE_URL" "$RESP"); then
        case "$STATUS" in
            404) echo "$(ts) gone (404)"; break ;;
            2??)
                NOW=$(json_field "$RESP" result.state)
                if [ "$NOW" != "$LAST" ]; then echo "$(ts) state: $NOW"; LAST=$NOW; fi
                ;;
            5??) echo "$(ts) poll: HTTP $STATUS, will retry" ;;
            *)   report_http_error "$STATUS" "$RESP"
                 echo "./$CONFIG_FILE is kept; check the console for the service." >&2
                 exit 1 ;;
        esac
    else
        echo "$(ts) poll: could not reach $API_URL, will retry"
    fi
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
        echo "timed out after ${TIMEOUT_SECONDS}s waiting for the service to disappear (last: ${LAST:-unknown})." >&2
        echo "./$CONFIG_FILE is kept. Re-run this script to keep waiting." >&2
        exit 1
    fi
    sleep "$POLL_SECONDS"
done

# --- set config.env aside ---------------------------------------------------
ASIDE="$CONFIG_FILE.deleted-$(date -u +%Y%m%dT%H%M%SZ)"
mv "$CONFIG_FILE" "$ASIDE"
chmod 600 "$ASIDE"
echo
echo "renamed ./$CONFIG_FILE -> ./$ASIDE (mode 600)."
echo "It still holds the old password for a service that no longer exists; remove it when you are done."
