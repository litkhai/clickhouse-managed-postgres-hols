#!/usr/bin/env bash
# Keep generating trips at the rate the real system would be running right now.
#
#   ./scripts/generate-trips.sh                 # every 60s, insert the last 60s
#   ./scripts/generate-trips.sh --interval 10
#   ./scripts/generate-trips.sh --scale 5       # five times real volume
#   ./scripts/generate-trips.sh --rounds 5      # then stop
#
# Ctrl-C stops it and reports. Unlike a fixed rate, the volume follows the
# hour-of-day and weekday/weekend shape measured from the loaded history, so a
# Tuesday 8am run inserts several times what a Tuesday 4am run does — which is
# the whole point of watching an aggregate move.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"

INTERVAL=60
SCALE=1.0
ROUNDS=0
SAMPLE=100000

while [ $# -gt 0 ]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2;;
        --scale)    SCALE="$2"; shift 2;;
        --rounds)   ROUNDS="$2"; shift 2;;
        --sample)   SAMPLE="$2"; shift 2;;
        -h|--help)  sed -n '2,12p' "$0"; exit 0;;
        *) echo "unknown option: $1" >&2; exit 2;;
    esac
done

SAMPLE_CSV=$(mktemp -t bike-live)
BATCH_CSV=$(mktemp -t bike-batch)
trap 'rm -f "$SAMPLE_CSV" "$BATCH_CSV"' EXIT

read -r WEEKDAY_BASE WEEKEND_BASE <<<"$(psql_c -tA -F' ' -c "
WITH d AS (SELECT started_at::date AS day, extract(dow FROM started_at) AS dow, count(*) AS n
           FROM bike.trips GROUP BY 1, 2),
full_days AS (SELECT * FROM d
              WHERE day > (SELECT min(started_at)::date FROM bike.trips)
                AND day < (SELECT max(started_at)::date FROM bike.trips))
SELECT round(avg(n) FILTER (WHERE dow BETWEEN 1 AND 5))::text,
       round(avg(n) FILTER (WHERE dow IN (0, 6)))::text FROM full_days")"

# Drawn once. Re-reading the pool every interval would make the sampling, not
# the insert, the thing the loop spends its time on.
STEP=$(psql_c -tA -c "SELECT greatest(1, (count(*) / $SAMPLE)::int) FROM bike.trips")
psql_c -c "\copy (
    SELECT bike_id, started_at, start_station_id, start_station_name, start_rack,
           end_station_id, end_station_name, end_rack, duration_min, distance_m,
           birth_year, gender, user_type, start_station_code, end_station_code
    FROM bike.trips
    WHERE start_station_id IS NOT NULL AND end_station_id IS NOT NULL
      AND mod(trip_id, $STEP) = 0
) TO STDOUT WITH (FORMAT csv, HEADER true)" > "$SAMPLE_CSV"

echo "target  : $(mask_host)"
echo "baseline: weekday $WEEKDAY_BASE / weekend $WEEKEND_BASE trips per day"
echo "pool    : $(( $(wc -l < "$SAMPLE_CSV") - 1 )) real trips, every ${STEP}th"
echo "rate    : whatever this hour of this weekday calls for, x$SCALE"
echo

inserted=0
round=0
started=$(date +%s)

finish() {
    local elapsed=$(( $(date +%s) - started ))
    echo
    echo "stopped after $round rounds, $inserted trips in ${elapsed}s"
    exit 0
}
trap finish INT TERM

while :; do
    round=$(( round + 1 ))
    # Generate to a file first, so the row count is the file's and not something
    # inferred: COPY prints no tag under psql -q, and counting the requests
    # instead of the rows would drift from what actually landed.
    python3 scripts/tripgen.py --minutes "$INTERVAL" --scale "$SCALE" \
        --weekday-base "$WEEKDAY_BASE" --weekend-base "$WEEKEND_BASE" \
        < "$SAMPLE_CSV" > "$BATCH_CSV" 2>/dev/null
    n=$(wc -l < "$BATCH_CSV" | tr -d ' ')
    if [ "$n" -gt 0 ]; then
        psql_stdin -c "COPY bike.trips (
            bike_id, started_at, start_station_id, start_station_name, start_rack,
            ended_at, end_station_id, end_station_name, end_rack, duration_min,
            distance_m, birth_year, gender, user_type, start_station_code, end_station_code)
        FROM STDIN WITH (FORMAT csv)" < "$BATCH_CSV"
        inserted=$(( inserted + n ))
    fi
    printf '\r  round %-4d  %s  +%-6s  %d trips total' \
        "$round" "$(date +%H:%M:%S)" "$n" "$inserted"

    [ "$ROUNDS" -gt 0 ] && [ "$round" -ge "$ROUNDS" ] && { echo; finish; }
    sleep "$INTERVAL"
done
