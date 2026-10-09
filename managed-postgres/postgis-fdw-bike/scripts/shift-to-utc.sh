#!/usr/bin/env bash
# Move bike.trips from Korean local time to UTC, in primary-key batches.
#
# ONLY FOR A DATABASE LOADED BEFORE 2026-08-15. scripts/load-trips.sh already
# stores UTC (it subtracts nine hours as it loads), so running this on a fresh
# load subtracts nine hours a second time, and a doubly-shifted row looks
# exactly like a valid one. So nothing changes without --from-kst, and once the
# shift has finished (bike.utc_shift.finished_at is set) it refuses even with
# the flag: every row added since, by the generator or by load-trips.sh, is
# already UTC and would be shifted wrongly.
#
#   ./scripts/shift-to-utc.sh --explain               # cost and progress, changes nothing
#   ./scripts/shift-to-utc.sh --from-kst              # run it; safe to interrupt and resume
#   ./scripts/shift-to-utc.sh --from-kst --batch 500000
#
# Exit status: 0 on success (--explain and --help included); 1 when the shift
# has already finished (--explain too); 2 for bad usage or a missing --from-kst.
#
# Why this needs care
# -------------------
# The source publishes Korean local time and the column is `timestamp without
# time zone`, so the values were KST wall-clock with nothing recording that.
# ClickHouse attaches a timezone to DateTime, so the same numbers would arrive
# meaning something nine hours different. Storing UTC removes the ambiguity;
# load-trips.sh now does that on load, and this is the same conversion for data
# that predates it.
#
# One UPDATE over 23.8M rows would rewrite every tuple in a single transaction:
# the table roughly doubles before autovacuum catches up, ~20 GB of WAL is
# generated, and none of it can be reclaimed until the whole thing commits. So
# this walks the primary key instead, committing each batch, which keeps the
# dead tuples collectable and the WAL drainable as it goes.
#
# Progress is recorded in bike.utc_shift, so an interrupted run resumes at the
# right key rather than shifting some rows twice — which would be invisible
# afterwards, because a doubly-shifted row looks exactly like a valid one.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"

BATCH=250000
OFFSET_HOURS=9          # Asia/Seoul is UTC+9 year round; Korea has no DST
EXPLAIN=""
FROM_KST=""
VACUUM_EVERY=8

while [ $# -gt 0 ]; do
    case "$1" in
        --batch)   BATCH="$2"; shift 2;;
        --explain) EXPLAIN=1; shift;;
        --from-kst) FROM_KST=1; shift;;
        -h|--help) sed -n '2,17p' "$0"; exit 0;;
        *) echo "unknown option: $1" >&2; exit 2;;
    esac
done

# Checked before anything touches the database. Nothing here can tell fresh UTC
# data from old KST data, so the caller has to say which one this is.
if [ -z "$FROM_KST" ] && [ -z "$EXPLAIN" ]; then
    cat >&2 <<'MSG'
Refusing to run without --from-kst. Nothing was changed.

scripts/load-trips.sh already stores UTC. Shifting data that is already UTC
subtracts nine hours a second time, and the result looks exactly like valid
data. Pass --from-kst only if this database was loaded before 2026-08-15 and
still holds Korean local time. --explain shows what would change.
MSG
    exit 2
fi

psql_stdin <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS bike.utc_shift (
    id            boolean PRIMARY KEY DEFAULT true CHECK (id),
    done_through  bigint  NOT NULL DEFAULT 0,
    rows_shifted  bigint  NOT NULL DEFAULT 0,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz
);
INSERT INTO bike.utc_shift (id) VALUES (true) ON CONFLICT DO NOTHING;
SQL

# finished_at is formatted without a space so `read` keeps it as one field.
read -r DONE SHIFTED MAXPK TOTAL FINISHED <<<"$(psql_c -tA -F' ' -c "
SELECT s.done_through, s.rows_shifted,
       coalesce(max(t.trip_id), 0), count(t.*),
       coalesce(to_char(s.finished_at, 'YYYY-MM-DD\"T\"HH24:MI:SSOF'), '-')
FROM bike.utc_shift s LEFT JOIN bike.trips t ON true
GROUP BY s.done_through, s.rows_shifted, s.finished_at")"

echo "target   : $(mask_host)"
echo "rows     : $TOTAL, primary key up to $MAXPK"
echo "progress : done through trip_id $DONE ($SHIFTED rows shifted so far)"
echo "batch    : $BATCH rows per transaction, offset -${OFFSET_HOURS}h"

# Before the "nothing left" test, which would answer 0 for a finished shift.
# Rows with trip_id above done_through were added after it finished and are
# already UTC; running again would shift every one of them a second time.
if [ "$FINISHED" != "-" ]; then
    echo >&2
    echo "refusing: the shift finished at $FINISHED" >&2
    echo "Rows added since then (trip_id > $DONE) are already UTC, so shifting" >&2
    echo "again would subtract nine hours from them. Nothing was changed." >&2
    exit 1
fi

if [ "$DONE" -ge "$MAXPK" ]; then
    echo
    echo "nothing left: every row up to $MAXPK is already UTC"
    exit 0
fi

REMAINING=$(( MAXPK - DONE ))
echo "remaining: ~$REMAINING keys, about $(( (REMAINING + BATCH - 1) / BATCH )) batches"

if [ -n "$EXPLAIN" ]; then
    echo
    echo "sample of what would change:"
    psql_c -c "
    SELECT trip_id, started_at AS kst_now, started_at - interval '$OFFSET_HOURS hours' AS utc_after
    FROM bike.trips WHERE trip_id > $DONE ORDER BY trip_id LIMIT 3;"
    exit 0
fi

echo
start=$(date +%s)
batch_no=0
while :; do
    batch_no=$(( batch_no + 1 ))
    # Bounded by key, not by a WHERE on the timestamp: once a row is shifted it
    # is indistinguishable from one that never needed shifting, so the key is
    # the only thing that can say what has been done.
    read -r NEWDONE MOVED <<<"$(psql_c -tA -F' ' -c "
    WITH slice AS (
        SELECT trip_id FROM bike.trips
        WHERE trip_id > $DONE ORDER BY trip_id LIMIT $BATCH
    ), moved AS (
        UPDATE bike.trips t
        SET started_at = t.started_at - interval '$OFFSET_HOURS hours',
            ended_at   = t.ended_at   - interval '$OFFSET_HOURS hours'
        FROM slice WHERE t.trip_id = slice.trip_id
        RETURNING t.trip_id
    ), bookmark AS (
        UPDATE bike.utc_shift
        SET done_through = coalesce((SELECT max(trip_id) FROM slice), done_through),
            rows_shifted = rows_shifted + (SELECT count(*) FROM moved)
        RETURNING done_through
    )
    SELECT (SELECT done_through FROM bookmark), (SELECT count(*) FROM moved)")"

    [ -n "$NEWDONE" ] || { echo; echo "no rows returned — stopping"; exit 1; }
    DONE="$NEWDONE"
    SHIFTED=$(( SHIFTED + MOVED ))
    printf '\r  batch %-4d  key %-10s  %10s rows shifted' "$batch_no" "$DONE" "$SHIFTED"

    [ "$MOVED" -eq 0 ] && break
    [ "$DONE" -ge "$MAXPK" ] && break

    # Let autovacuum reclaim the dead tuples periodically; without this the
    # table carries every old row version until the very end.
    if [ $(( batch_no % VACUUM_EVERY )) -eq 0 ]; then
        psql_c -c "VACUUM (SKIP_LOCKED) bike.trips" >/dev/null 2>&1 || true
    fi
done

elapsed=$(( $(date +%s) - start ))
psql_c -c "UPDATE bike.utc_shift SET finished_at = now()" >/dev/null
echo
echo
echo "── done in ${elapsed}s ────────────────────────────"
psql_c -c "VACUUM (ANALYZE) bike.trips" >/dev/null 2>&1 || true
psql_c -c "
SELECT to_char(min(started_at), 'YYYY-MM-DD HH24:MI') AS first_utc,
       to_char(max(started_at), 'YYYY-MM-DD HH24:MI') AS last_utc,
       count(*) AS rows,
       pg_size_pretty(pg_total_relation_size('bike.trips')) AS size
FROM bike.trips;"
echo "The weekday peak should now sit at 23:00 and 09:00 UTC (08 and 18 in Seoul):"
psql_c -c "
SELECT extract(hour FROM started_at)::int AS utc_hour, count(*) AS trips
FROM bike.trips WHERE extract(dow FROM started_at) BETWEEN 1 AND 5
GROUP BY 1 ORDER BY trips DESC LIMIT 3;"
