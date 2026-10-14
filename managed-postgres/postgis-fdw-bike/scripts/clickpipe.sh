#!/usr/bin/env bash
# The Postgres CDC ClickPipe from this lab's Managed Postgres into CH_DATABASE on
# ClickHouse Cloud, through the Cloud API.
#
#   ./scripts/clickpipe.sh create [--dry-run]   # make the database and the pipe
#   ./scripts/clickpipe.sh status               # pipe state, and the row counts on both sides
#   ./scripts/clickpipe.sh delete [--dry-run]   # delete the pipe, wait until it is gone
#
# The pipe replicates bike.trips and bike.stations into CH_DATABASE as
# bike_trips and bike_stations, the names sql/40-fdw-clickhouse.sql reads. It is
# found by its name, "mpg hols bike", so there is nothing to remember: create
# refuses when that name is taken, and delete removes only that one.
#
# Reads PGHOST, PGPORT, PGUSER, PGPASSWORD and PGDATABASE (the source) and
# CH_HOST, CH_PORT, CH_USER, CH_PASSWORD and CH_DATABASE (the destination) from
# config.env. CHC_ORG_ID, CHC_KEY_ID, CHC_KEY_SECRET and CHC_SERVICE_ID are
# taken from the environment; for any that are missing, from the file named by
# CHC_ENV_FILE, else from config.env. CHC_SERVICE_ID is the ClickHouse Cloud
# service the pipe belongs to (Console, service, Settings).
#
# CH_DATABASE must be a database of this lab's own. default, system, pg_sync and
# ny_citibike hold shared data and are refused.
#
# Neither password goes on a command line. The API secret and the request body,
# which carries the Postgres password, reach curl on stdin and through a file
# descriptor; the ClickHouse password reaches clickhouse-client as the
# CLICKHOUSE_PASSWORD environment variable.
#
# --dry-run prints the request, with the Postgres password shown as <redacted>
# and the host masked, and sends nothing.
#
# Knobs for tests and slow regions:
#   CHC_API_URL      default https://api.clickhouse.cloud
#   POLL_SECONDS     default 5     (delete: how often to ask whether the pipe is gone)
#   TIMEOUT_SECONDS  default 600   (delete: how long to keep asking)
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"
umask 077

POLL_SECONDS="${POLL_SECONDS:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"

usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; }

CMD="${1:-}"
[ $# -eq 0 ] || shift
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "unknown argument: $1" ;;
    esac
done
case "$CMD" in
    create|delete) ;;
    status) [ "$DRY_RUN" -eq 0 ] || die "--dry-run applies to create and delete only" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "usage: clickpipe.sh create|status|delete [--dry-run]" ;;
esac

RESP=""
trap 'rm -f "$RESP"' EXIT
RESP=$(mktemp)

ts() { date -u +%H:%M:%SZ; }

# API errors quote the Postgres host and its address ("3.4.5.6:5432 (<host>)"),
# so they are masked too. mask_stream only takes addresses in parentheses, which
# keeps version numbers alone; an address followed by a port is one as well.
report_http_error() {   # STATUS FILE
    echo "HTTP $1: $(json_field "$2" error)" \
        | mask_stream | sed -E 's#([0-9]{1,3}\.){3}[0-9]{1,3}:([0-9]+)#<ip>:\2#g' >&2
}

# ClickPipes verifies the Postgres certificate, and the Managed Postgres CA is
# not one it trusts: without this the create fails with "x509: certificate
# signed by unknown authority" (seen 2026-10-14). The API serves each service's
# CA as PEM. The service is PG_SERVICE_ID when config.env has it (a symlink to
# ../provisioning/config.env does), else the one whose hostname is PGHOST.
pg_ca_pem() {   # OUTFILE
    local id="${PG_SERVICE_ID:-}" status
    if [ -z "$id" ]; then
        status=$(chc_curl GET "/v1/organizations/$CHC_ORG_ID/postgres" "$1") \
            || die "request failed: could not reach $CHC_API_URL"
        case "$status" in 2??) ;; *) report_http_error "$status" "$1"; exit 1 ;; esac
        # The list carries no hostname (2026-10-14), so each service is read.
        local candidate
        for candidate in $(python3 -c 'import json,sys; [print(s["id"]) for s in json.load(open(sys.argv[1])).get("result", [])]' "$1"); do
            status=$(chc_curl GET "/v1/organizations/$CHC_ORG_ID/postgres/$candidate" "$1") || continue
            case "$status" in 2??) ;; *) continue ;; esac
            if [ "$(json_field "$1" result.hostname)" = "$PGHOST" ]; then id=$candidate; break; fi
        done
        [ -n "$id" ] || die "no Managed Postgres service in this organization has PGHOST as its hostname; set PG_SERVICE_ID"
    fi
    status=$(chc_curl GET "/v1/organizations/$CHC_ORG_ID/postgres/$id/caCertificates" "$1") \
        || die "request failed: could not reach $CHC_API_URL"
    case "$status" in 2??) ;; *) report_http_error "$status" "$1"; exit 1 ;; esac
    grep -q 'BEGIN CERTIFICATE' "$1" || die "the caCertificates response is not a PEM certificate"
}

PIPES_PATH_DRY="/v1/organizations/<org-id>/services/<service-id>/clickpipes"

# The request body. In `dry` mode the host is masked and the password is not in
# it, so the result can be printed; in `real` mode it is the body that gets sent.
# The values come through the environment, not argv.
pipe_body() {   # dry|real
    MASKED_HOST="$(mask_host)" MODE="$1" PIPE_NAME="$PIPE_NAME" CA_FILE="${2:-}" python3 - <<'PY'
import json, os
dry = os.environ["MODE"] == "dry"
env = os.environ
ca = "<PEM from GET .../postgres/<id>/caCertificates>" if dry else open(env["CA_FILE"]).read()
print(json.dumps({
    "name": env["PIPE_NAME"],
    "source": {"postgres": {
        "host": env["MASKED_HOST"] if dry else env["PGHOST"],
        "port": int(env["PGPORT"]),
        "database": env["PGDATABASE"],
        "credentials": {"username": env["PGUSER"],
                        "password": "<redacted>" if dry else env["PGPASSWORD"]},
        "caCertificate": ca,
        # cdc is the initial snapshot followed by the change stream.
        "settings": {"replicationMode": "cdc", "syncIntervalSeconds": 60},
        "tableMappings": [
            {"sourceSchemaName": "bike", "sourceTable": "trips",
             "targetTable": "bike_trips", "tableEngine": "ReplacingMergeTree"},
            {"sourceSchemaName": "bike", "sourceTable": "stations",
             "targetTable": "bike_stations", "tableEngine": "ReplacingMergeTree"}]}},
    "destination": {"database": env["CH_DATABASE"]},
}))
PY
}

# --- create -----------------------------------------------------------------
cmd_create() {
    ch_database_check
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "clickhouse-client on $(mask_host "${CH_HOST:-<service>.<region>.aws.clickhouse.cloud}"):"
        echo "  CREATE DATABASE IF NOT EXISTS \`$CH_DATABASE\`"
        echo
        echo "POST $CHC_API_URL$PIPES_PATH_DRY"
        pipe_body dry | python3 -m json.tool
        echo
        echo "dry run: nothing was sent."
        return 0
    fi

    ch_init
    chc_load

    # Refuse before touching anything: a second pipe on the same tables would
    # take a second slot and write the same rows into the same database.
    local found
    found=$(chc_find_pipes "$PIPE_NAME") || exit 1
    if [ -n "$found" ]; then
        local id state
        IFS=$'\t' read -r id state <<< "$(printf '%s\n' "$found" | head -n 1)"
        echo "refusing: a ClickPipe named \"$PIPE_NAME\" already exists." >&2
        echo "  id:    $id" >&2
        echo "  state: $state" >&2
        echo "Delete it first with ./scripts/clickpipe.sh delete (or ./scripts/teardown.sh)." >&2
        exit 1
    fi

    echo "$(ts) clickhouse: CREATE DATABASE IF NOT EXISTS \`$CH_DATABASE\` on $(mask_host "$CH_HOST")"
    ch_client -q "CREATE DATABASE IF NOT EXISTS \`$CH_DATABASE\`"

    echo "$(ts) creating the pipe ..."
    local body status ca
    ca=$(mktemp)
    pg_ca_pem "$ca"
    body=$(pipe_body real "$ca")
    rm -f "$ca"
    status=$(chc_curl POST "$(chc_pipes_path)" "$RESP" "$body") \
        || die "request failed: could not reach $CHC_API_URL"
    case "$status" in
        2??) ;;
        *) report_http_error "$status" "$RESP"; exit 1 ;;
    esac

    local pipe_id pipe_state
    pipe_id=$(json_field "$RESP" result.id)
    pipe_state=$(json_field "$RESP" result.state)
    [[ "$pipe_id" =~ $PIPE_ID_RE ]] \
        || die "the response had no usable result.id; check the Console for a pipe you did not mean to create"

    echo "$(ts) created."
    echo "id          : $pipe_id"
    echo "state       : ${pipe_state:-unknown}"
    echo "destination : $CH_DATABASE (bike_trips, bike_stations)"
    echo "slot        : $(pipe_slot_name "$pipe_id")   (the names ClickPipes gave the pipes seen on 2026-10-14)"
    echo "publication : $(pipe_pub_name "$pipe_id")"
    echo
    echo "next: ./scripts/clickpipe.sh status      # until it is Running and the counts agree"
    echo "      ./scripts/psql.sh -f /sql/40-fdw-clickhouse.sql"
}

# --- status -----------------------------------------------------------------
pg_count() {   # TABLE
    psql_c -tA -c "SELECT count(*) FROM bike.$1" || echo "n/a"
}
ch_count() {   # TABLE -> the count, or n/a with the reason on stderr
    local out
    if out=$(ch_client -q "SELECT count() FROM \`$CH_DATABASE\`.$1" 2>&1); then
        printf '%s\n' "$out"
    else
        echo "n/a"
        printf '  clickhouse %s: %s\n' "$1" "$(printf '%s\n' "$out" | grep -m1 'DB::Exception' | cut -c1-160)" >&2
    fi
}

cmd_status() {
    ch_init
    chc_load

    local found id state
    found=$(chc_find_pipes "$PIPE_NAME") || exit 1
    if [ -z "$found" ]; then
        echo "pipe        : none named \"$PIPE_NAME\""
    else
        IFS=$'\t' read -r id state <<< "$(printf '%s\n' "$found" | head -n 1)"
        echo "pipe        : $PIPE_NAME"
        echo "id          : $id"
        echo "state       : $state"
        if [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" -gt 1 ]; then
            echo "warning     : more than one pipe has this name; showing the first" >&2
        fi
    fi
    echo "database    : $CH_DATABASE on $(mask_host "$CH_HOST")"
    echo
    # count() on a ReplacingMergeTree reads every part as it is, so a row that was
    # updated, or deleted, can still be counted twice until a merge. These are
    # the numbers before merging; the two sides settle to the same figure once
    # the snapshot is done and the table has merged, not before.
    local pt ps ct cs
    pt=$(pg_count trips); ps=$(pg_count stations)
    ct=$(ch_count bike_trips); cs=$(ch_count bike_stations)
    printf '%-10s %14s %14s\n' "" "postgres" "clickhouse"
    printf '%-10s %14s %14s\n' "trips" "$pt" "$ct"
    printf '%-10s %14s %14s\n' "stations" "$ps" "$cs"
    echo
    echo "clickhouse counts are before merging (no FINAL)."
}

# --- delete -----------------------------------------------------------------
cmd_delete() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "GET    $CHC_API_URL$PIPES_PATH_DRY            # find the pipe named \"$PIPE_NAME\""
        echo "DELETE $CHC_API_URL$PIPES_PATH_DRY/<pipe-id>"
        echo "GET    $CHC_API_URL$PIPES_PATH_DRY/<pipe-id>  # every ${POLL_SECONDS}s until HTTP 404, at most ${TIMEOUT_SECONDS}s"
        echo
        echo "dry run: nothing was sent."
        return 0
    fi

    chc_load
    local found id state
    found=$(chc_find_pipes "$PIPE_NAME") || exit 1
    if [ -z "$found" ]; then
        echo "no ClickPipe named \"$PIPE_NAME\"; nothing to delete."
        return 0
    fi
    if [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" -gt 1 ]; then
        echo "refusing: more than one ClickPipe is named \"$PIPE_NAME\":" >&2
        printf '%s\n' "$found" | sed 's/^/  /' >&2
        echo "Delete the ones you do not want in the Console, then run this again." >&2
        exit 1
    fi
    IFS=$'\t' read -r id state <<< "$found"
    [[ "$id" =~ $PIPE_ID_RE ]] || die "the pipe list gave an id that is not a UUID: $id"

    echo "$(ts) deleting $id (state: ${state:-unknown}) ..."
    local status
    status=$(chc_curl DELETE "$(chc_pipes_path)/$id" "$RESP") \
        || die "request failed: could not reach $CHC_API_URL"
    case "$status" in
        2??) ;;
        *) report_http_error "$status" "$RESP"; exit 1 ;;
    esac

    # The DELETE returns before the pipe is gone: it tears down its replication
    # connection first. 404 on the pipe is the only answer that means gone.
    local last="" now deadline=$(( SECONDS + TIMEOUT_SECONDS ))
    while :; do
        if status=$(chc_curl GET "$(chc_pipes_path)/$id" "$RESP"); then
            case "$status" in
                404) echo "$(ts) gone."; return 0 ;;
                2??) now=$(json_field "$RESP" result.state)
                     if [ "$now" != "$last" ]; then echo "$(ts) state: ${now:-unknown}"; last=$now; fi ;;
                5??) echo "$(ts) poll: HTTP $status, will retry" ;;
                *)   report_http_error "$status" "$RESP"
                     echo "the DELETE was accepted; check the Console for the pipe's state." >&2
                     exit 1 ;;
            esac
        else
            echo "$(ts) poll: could not reach $CHC_API_URL, will retry"
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "timed out after ${TIMEOUT_SECONDS}s waiting for the pipe to disappear (last state: ${last:-unknown})." >&2
            echo "Run ./scripts/clickpipe.sh delete again, or look at the Console." >&2
            exit 1
        fi
        sleep "$POLL_SECONDS"
    done
}

"cmd_$CMD"
