#!/usr/bin/env bash
# Fill the hours between the newest trip and now.
#
#   ./scripts/catch-up.sh            # newest row .. now
#   ./scripts/catch-up.sh --explain
#
# backfill-trips.sh works in whole days and stops at yesterday, so it cannot
# close the tail: a table whose newest row is yesterday afternoon still counts
# every day as covered. This closes that, and is what to run before starting
# the live generator so the feed does not begin with a hole behind it.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"

EXPLAIN=""; SCALE=1.0; SAMPLE=200000
while [ $# -gt 0 ]; do
    case "$1" in
        --scale)   SCALE="$2"; shift 2;;
        --sample)  SAMPLE="$2"; shift 2;;
        --explain) EXPLAIN=1; shift;;
        -h|--help) sed -n '2,10p' "$0"; exit 0;;
        *) echo "unknown option: $1" >&2; exit 2;;
    esac
done

read -r SINCE UNTIL BEHIND <<<"$(psql_c -tA -F' ' -c "
SELECT to_char(max(started_at), 'YYYY-MM-DD\"T\"HH24:MI:SS'),
       to_char(now()::timestamp, 'YYYY-MM-DD\"T\"HH24:MI:SS'),
       extract(epoch FROM now()::timestamp - max(started_at))::bigint
FROM bike.trips")"

echo "target : $(mask_host)"
echo "newest : $SINCE (UTC)"
echo "now    : $UNTIL (UTC)"
printf 'behind : %dh %dm\n' $(( BEHIND / 3600 )) $(( BEHIND % 3600 / 60 ))

if [ "$BEHIND" -lt 300 ]; then
    echo; echo "already current"; exit 0
fi

read -r WEEKDAY_BASE WEEKEND_BASE <<<"$(psql_c -tA -F' ' -c "
WITH d AS (SELECT started_at::date AS day, extract(dow FROM started_at) AS dow, count(*) AS n
           FROM bike.trips GROUP BY 1, 2),
f AS (SELECT * FROM d WHERE day > (SELECT min(started_at)::date FROM bike.trips)
                        AND day < (SELECT max(started_at)::date FROM bike.trips))
SELECT round(avg(n) FILTER (WHERE dow BETWEEN 1 AND 5))::text,
       round(avg(n) FILTER (WHERE dow IN (0,6)))::text FROM f")"

DAYS_FILE=$(mktemp -t bike-cdays); SAMPLE_CSV=$(mktemp -t bike-csample)
trap 'rm -f "$DAYS_FILE" "$SAMPLE_CSV"' EXIT
psql_c -tA -c "SELECT d::date FROM generate_series(DATE '${SINCE%%T*}', DATE '${UNTIL%%T*}', interval '1 day') d" > "$DAYS_FILE"

STEP=$(psql_c -tA -c "SELECT greatest(1, (count(*) / $SAMPLE)::int) FROM bike.trips")
psql_c -c "\copy (
    SELECT bike_id, started_at, start_station_id, start_station_name, start_rack,
           end_station_id, end_station_name, end_rack, duration_min, distance_m,
           birth_year, gender, user_type, start_station_code, end_station_code
    FROM bike.trips
    WHERE start_station_id IS NOT NULL AND end_station_id IS NOT NULL
      AND mod(trip_id, $STEP) = 0
) TO STDOUT WITH (FORMAT csv, HEADER true)" > "$SAMPLE_CSV"

GEN=(python3 scripts/tripgen.py --days-file "$DAYS_FILE" --scale "$SCALE"
     --weekday-base "$WEEKDAY_BASE" --weekend-base "$WEEKEND_BASE"
     --since "$SINCE" --until "$UNTIL")

if [ -n "$EXPLAIN" ]; then
    echo; echo "would generate for $(grep -c . "$DAYS_FILE") day(s), clipped to the window above"
    exit 0
fi

echo
"${GEN[@]}" < "$SAMPLE_CSV" \
  | psql_stdin -c "COPY bike.trips (
        bike_id, started_at, start_station_id, start_station_name, start_rack,
        ended_at, end_station_id, end_station_name, end_rack, duration_min,
        distance_m, birth_year, gender, user_type, start_station_code, end_station_code)
    FROM STDIN WITH (FORMAT csv)"

psql_c -c "ANALYZE bike.trips" >/dev/null
psql_c -c "
SELECT to_char(max(started_at), 'YYYY-MM-DD HH24:MI') AS newest_utc,
       extract(epoch FROM now()::timestamp - max(started_at))::int AS seconds_behind,
       count(*) AS rows
FROM bike.trips;"
