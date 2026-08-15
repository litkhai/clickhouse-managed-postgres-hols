#!/usr/bin/env bash
# Fill the gap between the loaded history and today, leaving no missing days.
#
#   ./scripts/backfill-trips.sh --explain          # what it would write
#   ./scripts/backfill-trips.sh --scale 0.1        # a tenth of real volume
#   ./scripts/backfill-trips.sh                    # full volume, asks first
#   ./scripts/backfill-trips.sh --from 2026-02-01 --to 2026-03-31
#
# Defaults to the day after the newest loaded trip through yesterday, so
# running it twice does not double up and the live generator owns today.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"

SCALE=1.0
FROM=""; TO=""; EXPLAIN=""; SEED=""; SAMPLE=200000
while [ $# -gt 0 ]; do
    case "$1" in
        --scale)   SCALE="$2"; shift 2;;
        --from)    FROM="$2"; shift 2;;
        --to)      TO="$2"; shift 2;;
        --seed)    SEED="--seed $2"; shift 2;;
        --sample)  SAMPLE="$2"; shift 2;;
        --explain) EXPLAIN="--explain"; shift;;
        -h|--help) sed -n '2,13p' "$0"; exit 0;;
        *) echo "unknown option: $1" >&2; exit 2;;
    esac
done

[ -n "$FROM" ] || FROM=$(psql_c -tA -c "SELECT min(started_at)::date::text FROM bike.trips")
[ -n "$TO" ]   || TO=$(psql_c -tA -c "SELECT (current_date - 1)::text")
[ -n "$FROM" ] || { echo "bike.trips is empty — load a month first" >&2; exit 1; }

# Ask which days are actually missing rather than assuming the gap is a tail.
# Taking max(started_at)+1 as the start looked reasonable and was wrong: one
# streaming test had already put rows on today's date, so the whole of February
# to August counted as "already covered".
DAYS_FILE=$(mktemp -t bike-days)
SAMPLE_CSV=$(mktemp -t bike-sample)
trap 'rm -f "$DAYS_FILE" "$SAMPLE_CSV"' EXIT

psql_c -tA -c "
SELECT d::date
FROM generate_series(DATE '$FROM', DATE '$TO', interval '1 day') d
WHERE NOT EXISTS (
    SELECT 1 FROM bike.trips t WHERE t.started_at >= d AND t.started_at < d + interval '1 day')
ORDER BY 1" > "$DAYS_FILE"

MISSING=$(grep -c . "$DAYS_FILE" || true)
if [ "$MISSING" -eq 0 ]; then
    echo "nothing to fill: every day from $FROM to $TO already has trips"; exit 0
fi

echo "target : $(mask_host)"
echo "window : $FROM .. $TO"
echo "missing: $MISSING days  (scale $SCALE)"
echo

# How busy a real day is, measured over every loaded day rather than guessed
# from the sample. Partial days at the edges are excluded so they do not drag
# the average down.
read -r WEEKDAY_BASE WEEKEND_BASE <<<"$(psql_c -tA -F' ' -c "
WITH d AS (
    SELECT started_at::date AS day, extract(dow FROM started_at) AS dow, count(*) AS n
    FROM bike.trips GROUP BY 1, 2
), full_days AS (
    SELECT * FROM d
    WHERE day > (SELECT min(started_at)::date FROM bike.trips)
      AND day < (SELECT max(started_at)::date FROM bike.trips)
)
SELECT round(avg(n) FILTER (WHERE dow BETWEEN 1 AND 5))::text,
       round(avg(n) FILTER (WHERE dow IN (0, 6)))::text
FROM full_days")"
echo "── measured baseline ──────────────────────────────"
echo "  weekday $WEEKDAY_BASE / weekend $WEEKEND_BASE trips per day"
echo

# Spread the sample across the whole table with a modulus rather than taking a
# prefix. ORDER BY trip_id LIMIT looked cheaper and produced a pool drawn
# entirely from the New Year holiday, which is not what a February Tuesday
# looks like.
echo "── sampling ~$SAMPLE real trips to draw from ──────"
STEP=$(psql_c -tA -c "SELECT greatest(1, (count(*) / $SAMPLE)::int) FROM bike.trips")
psql_c -c "\copy (
    SELECT bike_id, started_at, start_station_id, start_station_name, start_rack,
           end_station_id, end_station_name, end_rack, duration_min, distance_m,
           birth_year, gender, user_type, start_station_code, end_station_code
    FROM bike.trips
    WHERE start_station_id IS NOT NULL AND end_station_id IS NOT NULL
      AND mod(trip_id, $STEP) = 0
) TO STDOUT WITH (FORMAT csv, HEADER true)" > "$SAMPLE_CSV"
echo "  $(( $(wc -l < "$SAMPLE_CSV") - 1 )) rows, every ${STEP}th trip"
echo

if [ -n "$EXPLAIN" ]; then
    python3 scripts/tripgen.py --days-file "$DAYS_FILE" --scale "$SCALE" $SEED \
        --weekday-base "$WEEKDAY_BASE" --weekend-base "$WEEKEND_BASE" --explain \
        < "$SAMPLE_CSV"
    exit 0
fi

# Full volume across several months is millions of rows, and every one of them
# replicates downstream. Say so before doing it.
echo "── plan ───────────────────────────────────────────"
python3 scripts/tripgen.py --days-file "$DAYS_FILE" --scale "$SCALE" $SEED \
        --weekday-base "$WEEKDAY_BASE" --weekend-base "$WEEKEND_BASE" --explain \
    < "$SAMPLE_CSV"
echo
if [ -t 0 ]; then
    read -p "proceed? (yes/no) " answer
    [ "$answer" = "yes" ] || { echo "stopped"; exit 0; }
fi

echo
echo "── generating and loading ─────────────────────────"
python3 scripts/tripgen.py --days-file "$DAYS_FILE" --scale "$SCALE" $SEED \
        --weekday-base "$WEEKDAY_BASE" --weekend-base "$WEEKEND_BASE" < "$SAMPLE_CSV" \
  | psql_stdin -c "COPY bike.trips (
        bike_id, started_at, start_station_id, start_station_name, start_rack,
        ended_at, end_station_id, end_station_name, end_rack, duration_min,
        distance_m, birth_year, gender, user_type, start_station_code, end_station_code)
    FROM STDIN WITH (FORMAT csv)"

echo
psql_c -c "ANALYZE bike.trips;"
psql_c -c "
SELECT to_char(min(started_at), 'YYYY-MM-DD') AS first_day,
       to_char(max(started_at), 'YYYY-MM-DD') AS last_day,
       count(DISTINCT started_at::date)       AS days_present,
       (max(started_at)::date - min(started_at)::date + 1) AS days_expected,
       count(*)                               AS trips,
       pg_size_pretty(pg_total_relation_size('bike.trips')) AS size
FROM bike.trips;"
echo "OK: gap filled."
