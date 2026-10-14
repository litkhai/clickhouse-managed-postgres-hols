#!/usr/bin/env bash
# Remove everything this lab created outside the bike and bikegen data, in the
# order that lets each step succeed:
#
#   ./scripts/teardown.sh --dry-run   # print the steps, touch nothing
#   ./scripts/teardown.sh             # ask once, then do them
#   ./scripts/teardown.sh --yes
#
#   1. unschedule the pg_cron job "bike-generate"          (Postgres)
#   2. delete the ClickPipe "mpg hols bike"                (clickpipe.sh delete)
#   3. drop that pipe's replication slot and publication   (Postgres)
#   4. DROP SERVER chsrv CASCADE and DROP SCHEMA ch CASCADE (Postgres)
#   5. DROP DATABASE CH_DATABASE                           (ClickHouse Cloud)
#
# Each step checks first and says what it did, so running it again after a
# failure, or on a lab that was only half set up, is safe.
#
# Step 3 drops only the two objects named after the pipe's id (peerflow_slot_
# mirror_<id> and peerflow_pub_mirror_<id>, with every '-' in the id written as
# '__'). The service may host other pipes, so nothing is matched by pattern. The
# id is read before step 2 deletes the pipe; if the pipe is already gone the id
# is not known, and step 3 lists the slots there are and leaves them alone.
#
# CH_DATABASE must be a database of this lab's own: default, system, pg_sync and
# ny_citibike are refused, in dry-run too.
#
# The bike schema, its tables and the data in them are left alone; drop the
# service with ../provisioning/99-delete-service.sh when the lab is finished.
#
# Knobs: CHC_API_URL, POLL_SECONDS (see clickpipe.sh), and TIMEOUT_SECONDS
# (default 120): how long step 3 waits for the slot to go inactive once the pipe
# is gone.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"
umask 077

POLL_SECONDS="${POLL_SECONDS:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-120}"

usage() { sed -n '2,/^set -euo/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; }

DRY_RUN=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes)     ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "unknown argument: $1" ;;
    esac
done

# The refuse-list first, so a wrong CH_DATABASE fails before any question.
ch_database_check

CH_SHOWN="$(mask_host "${CH_HOST:-<service>.<region>.aws.clickhouse.cloud}")"

echo "teardown for the Postgres service $(mask_host) and the ClickHouse database \`$CH_DATABASE\` on $CH_SHOWN:"
echo "  1. unschedule the pg_cron job \"bike-generate\" (if there is one)"
echo "  2. delete the ClickPipe \"$PIPE_NAME\" (if there is one) and wait until it is gone"
echo "  3. drop the pipe's replication slot peerflow_slot_mirror_<pipe id, '-' as '__'>"
echo "     and publication peerflow_pub_mirror_<same> (only those two names)"
echo "  4. DROP SERVER IF EXISTS chsrv CASCADE; DROP SCHEMA IF EXISTS ch CASCADE"
echo "  5. DROP DATABASE IF EXISTS \`$CH_DATABASE\`"
echo "  bike.* and bikegen data stay."

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "dry run: nothing was changed."
    exit 0
fi

# Everything needed for all five steps, before the first one starts.
ch_init
chc_load

if [ "$ASSUME_YES" -ne 1 ]; then
    printf '\nDo this? The ClickHouse database and its data are dropped. [y/N] '
    ANSWER=""
    read -r ANSWER || true
    case "$ANSWER" in y|Y) ;; *) echo "nothing was changed."; exit 0 ;; esac
fi
echo

# --- 1. the pg_cron job ------------------------------------------------------
# bike.generator_unschedule() only exists once 30-generator-in-db.sql has run, so
# the job table itself is checked. pg_cron may not be installed at all.
# Assigned first, so a failed connection stops the script instead of reading as
# "no job".
HAS_CRON=$(psql_c -tA -c "SELECT to_regclass('cron.job') IS NOT NULL")
JOBS=0
if [ "$HAS_CRON" = "t" ]; then
    JOBS=$(psql_c -tA -c "SELECT count(*) FROM cron.job WHERE jobname = 'bike-generate'")
fi
if [ "$HAS_CRON" != "t" ]; then
    echo "1. pg_cron: no cron.job here; nothing to unschedule."
elif [ "$JOBS" -gt 0 ]; then
    psql_c -tA -c "SELECT cron.unschedule('bike-generate')" >/dev/null
    echo "1. pg_cron: unscheduled bike-generate."
else
    echo "1. pg_cron: bike-generate is not scheduled."
fi

# --- 2. the ClickPipe --------------------------------------------------------
# The id is remembered here: once the pipe is deleted nothing else says which
# slot and publication were its.
FOUND=$(chc_find_pipes "$PIPE_NAME") || exit 1
PIPE_ID=""
if [ -n "$FOUND" ]; then
    [ "$(printf '%s\n' "$FOUND" | wc -l | tr -d ' ')" -eq 1 ] \
        || die "2. more than one ClickPipe is named \"$PIPE_NAME\"; clickpipe.sh delete says which."
    PIPE_ID="${FOUND%%$'\t'*}"
    [[ "$PIPE_ID" =~ $PIPE_ID_RE ]] || die "2. the pipe list gave an id that is not a UUID: $PIPE_ID"
    echo "2. clickpipe: \"$PIPE_NAME\" is $PIPE_ID; clickpipe.sh delete:"
    "$LAB_DIR/scripts/clickpipe.sh" delete
else
    echo "2. clickpipe: no pipe named \"$PIPE_NAME\"."
fi

# --- 3. the slot and the publication -----------------------------------------
if [ -z "$PIPE_ID" ]; then
    echo "3. slot and publication: the pipe id is not known, so nothing is dropped."
    echo "   Slots here that look like ClickPipes':"
    psql_c -tA -F ' ' -c "SELECT '     ' || slot_name || '  active=' || active
                          FROM pg_replication_slots WHERE slot_name LIKE 'peerflow\\_%'"
    echo "   If one is this lab's: SELECT pg_drop_replication_slot('<name>'); and DROP PUBLICATION <the matching peerflow_pub_...>;"
else
    SLOT=$(pipe_slot_name "$PIPE_ID")
    PUB=$(pipe_pub_name "$PIPE_ID")
    # DELETE returns before the pipe has let go of its replication connection; a
    # slot that is still active cannot be dropped, so wait for it.
    DEADLINE=$(( SECONDS + TIMEOUT_SECONDS ))
    while :; do
        ACTIVE=$(psql_c -tA -c "SELECT active FROM pg_replication_slots WHERE slot_name = '$SLOT'")
        case "$ACTIVE" in
            "") echo "3. slot $SLOT: not there."; break ;;
            f)  psql_c -tA -c "SELECT pg_drop_replication_slot('$SLOT')" >/dev/null
                echo "3. slot $SLOT: dropped."; break ;;
        esac
        if [ "$SECONDS" -ge "$DEADLINE" ]; then
            echo "3. slot $SLOT is still active after ${TIMEOUT_SECONDS}s; it was not dropped." >&2
            echo "   Drop it by hand once it goes inactive: SELECT pg_drop_replication_slot('$SLOT');" >&2
            echo "   and: DROP PUBLICATION IF EXISTS $PUB;" >&2
            exit 1
        fi
        sleep "$POLL_SECONDS"
    done
    HAD_PUB=$(psql_c -tA -c "SELECT count(*) FROM pg_publication WHERE pubname = '$PUB'")
    if [ "$HAD_PUB" -gt 0 ]; then
        psql_c -c "DROP PUBLICATION \"$PUB\""
        echo "3. publication $PUB: dropped."
    else
        echo "3. publication $PUB: not there."
    fi
fi

# --- 4. the foreign server and the ch schema ---------------------------------
HAD_SERVER=$(psql_c -tA -c "SELECT count(*) FROM pg_foreign_server WHERE srvname = 'chsrv'")
HAD_SCHEMA=$(psql_c -tA -c "SELECT count(*) FROM pg_namespace WHERE nspname = 'ch'")
psql_c -c "DROP SERVER IF EXISTS chsrv CASCADE"
psql_c -c "DROP SCHEMA IF EXISTS ch CASCADE"
[ "$HAD_SERVER" -gt 0 ] && echo "4. server chsrv: dropped (with its user mapping)." || echo "4. server chsrv: not there."
[ "$HAD_SCHEMA" -gt 0 ] && echo "4. schema ch: dropped." || echo "4. schema ch: not there."

# --- 5. the ClickHouse database ----------------------------------------------
HAD_DB=$(ch_client -q "SELECT count() FROM system.databases WHERE name = '$CH_DATABASE'")
ch_client -q "DROP DATABASE IF EXISTS \`$CH_DATABASE\`"
if [ "$HAD_DB" -gt 0 ]; then
    echo "5. clickhouse: database \`$CH_DATABASE\` dropped on $CH_SHOWN."
else
    echo "5. clickhouse: database \`$CH_DATABASE\` was not there."
fi

echo
echo "done. bike.* is untouched; ../provisioning/99-delete-service.sh removes the Postgres service."
