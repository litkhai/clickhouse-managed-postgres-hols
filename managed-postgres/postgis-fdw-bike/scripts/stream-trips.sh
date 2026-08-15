#!/usr/bin/env bash
# Keep inserting trips in the same shape as the history, so aggregates have
# something that moves.
#
#   ./scripts/stream-trips.sh                    # 200 trips every 2s, forever
#   ./scripts/stream-trips.sh --rate 2000        # 2000 per batch
#   ./scripts/stream-trips.sh --batches 10       # then stop
#   ./scripts/stream-trips.sh --interval 0.5
#
# Ctrl-C stops it and prints what it inserted.
#
# Where the rows come from: the loaded history, sampled. Origin–destination
# pairs in this system are anything but uniform — a handful of stations near
# river crossings and campuses carry a disproportionate share, and duration
# tracks the pair — so inventing pairs uniformly would produce a table that
# aggregates into a shape the real one never takes. Sampling real pairs keeps
# the joins, the skew and the geography honest, and only the timestamps are
# new. It also means this needs no data files: everything comes from the table
# that is already there.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RATE=200
INTERVAL=2
BATCHES=0          # 0 = run until interrupted

while [ $# -gt 0 ]; do
    case "$1" in
        --rate)     RATE="$2"; shift 2;;
        --interval) INTERVAL="$2"; shift 2;;
        --batches)  BATCHES="$2"; shift 2;;
        -h|--help)  sed -n '2,16p' "$0"; exit 0;;
        *) echo "unknown option: $1" >&2; exit 2;;
    esac
done

echo "target   : $(mask_host)"
echo "inserting: $RATE trips every ${INTERVAL}s$([ "$BATCHES" -gt 0 ] && echo ", $BATCHES batches" || echo ", until Ctrl-C")"
echo

# A sample of the history to draw from. Materialised once: re-sampling 1.6M rows
# on every batch would make the generator, not the insert, the thing being
# measured.
psql_stdin <<SQL
DROP TABLE IF EXISTS bike.trip_shapes;
-- Number the rows *after* sampling. A row_number() in the same SELECT as
-- ORDER BY random() LIMIT is applied before the limit, so n comes out sparse
-- over the whole 1.6M-row scan (5 .. 1631593 when this was written) and the
-- lookup below then misses all but a handful of rows.
CREATE TABLE bike.trip_shapes AS
SELECT row_number() OVER () AS n, s.*
FROM (
    SELECT bike_id, start_station_id, start_station_name, start_rack,
           end_station_id, end_station_name, end_rack,
           duration_min, distance_m, birth_year, gender, user_type,
           start_station_code, end_station_code
    FROM bike.trips
    WHERE start_station_id IS NOT NULL AND end_station_id IS NOT NULL
    ORDER BY random()
    LIMIT 50000
) s;
CREATE INDEX ON bike.trip_shapes (n);
ANALYZE bike.trip_shapes;
SQL
SHAPES=$(psql_c -tA -c "SELECT count(*) FROM bike.trip_shapes")
echo "  drew $SHAPES real trip shapes to sample from"
echo

inserted=0
batch=0
started=$(date +%s)

finish() {
    local elapsed=$(( $(date +%s) - started ))
    echo
    echo "stopped after ${batch} batches, ${inserted} trips in ${elapsed}s"
    [ "$elapsed" -gt 0 ] && echo "average $(( inserted / elapsed )) trips/s"
    exit 0
}
trap finish INT TERM

while :; do
    batch=$(( batch + 1 ))
    # started_at is now minus the trip's own duration, so a trip that just ended
    # looks like one that started when it actually would have.
    # Count what actually landed. `n IN (...)` collapses duplicate draws, so a
    # batch comes in slightly under --rate; counting requests instead of rows
    # would quietly overstate the total. RETURNING rather than the command tag,
    # because psql -q does not print the tag.
    n=$(psql_c -tA -c "
WITH ins AS (
INSERT INTO bike.trips
SELECT bike_id,
       now()::timestamp - make_interval(mins => coalesce(duration_min, 0)),
       start_station_id, start_station_name, start_rack,
       now()::timestamp,
       end_station_id, end_station_name, end_rack,
       duration_min, distance_m, birth_year, gender, user_type,
       start_station_code, end_station_code
FROM bike.trip_shapes
WHERE n IN (
    SELECT (random() * ($SHAPES - 1))::int + 1 FROM generate_series(1, $RATE)
)
RETURNING 1)
SELECT count(*) FROM ins;")
    inserted=$(( inserted + n ))
    printf '\r  batch %-5d  %8d trips inserted' "$batch" "$inserted"

    [ "$BATCHES" -gt 0 ] && [ "$batch" -ge "$BATCHES" ] && { echo; finish; }
    sleep "$INTERVAL"
done
