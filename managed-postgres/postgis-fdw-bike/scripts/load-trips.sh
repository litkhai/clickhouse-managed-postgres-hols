#!/usr/bin/env bash
# Load historical trips into Postgres.
#
#   ./scripts/load-trips.sh                # every data/trips_*.csv
#   ./scripts/load-trips.sh 2601 2602      # only those months
#
# ~1.6M rows per month. The source CSV is CP949, so it is transcoded on the way
# through; nothing is written to disk in between.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"

if [ $# -gt 0 ]; then
    FILES=()
    for m in "$@"; do FILES+=("data/trips_${m}.csv"); done
else
    FILES=(data/trips_*.csv)
fi
[ -e "${FILES[0]}" ] || { echo "no trip CSVs — run ./scripts/fetch-data.sh first" >&2; exit 1; }

echo "target : $(mask_host)"
echo

# The source has 16 columns in a fixed order. Landing them in a staging table as
# text first means a stray value fails a cast we control, with a column name in
# the message, instead of failing inside COPY where the report is far vaguer.
psql_stdin <<'SQL'
CREATE UNLOGGED TABLE IF NOT EXISTS bike.trips_raw (
    bike_id text, started_at text, start_station_id text, start_station_name text,
    start_rack text, ended_at text, end_station_id text, end_station_name text,
    end_rack text, duration_min text, distance_m text, birth_year text,
    gender text, user_type text, start_station_code text, end_station_code text
);
TRUNCATE bike.trips_raw;
SQL

for f in "${FILES[@]}"; do
    [ -s "$f" ] || { echo "  missing $f — skipping" >&2; continue; }
    echo "── $(basename "$f")  ($(du -h "$f" | cut -f1))"
    # iconv drops the few byte sequences that are not valid CP949 rather than
    # aborting the whole load on them.
    iconv -f CP949 -t UTF-8//IGNORE < "$f" \
      | psql_stdin -c "COPY bike.trips_raw FROM STDIN WITH (FORMAT csv, HEADER true)"
    echo "  staged"
done

echo
echo "── typing and inserting ───────────────────────────"
psql_stdin <<'SQL'
-- Column list, not a bare INSERT: trip_id is GENERATED ALWAYS, so the
-- positional form would try to write it and fail.
INSERT INTO bike.trips (
    bike_id, started_at, start_station_id, start_station_name, start_rack,
    ended_at, end_station_id, end_station_name, end_rack, duration_min,
    distance_m, birth_year, gender, user_type, start_station_code, end_station_code)
SELECT bike_id,
       -- The portal publishes Korean local time. Store UTC: the column has no
       -- zone, and ClickHouse would attach its own to whatever arrives.
       started_at::timestamp - interval '9 hours',
       nullif(start_station_id, '')::integer,
       start_station_name,
       nullif(start_rack, '')::integer,
       nullif(ended_at, '')::timestamp - interval '9 hours',
       nullif(end_station_id, '')::integer,
       end_station_name,
       nullif(end_rack, '')::integer,
       nullif(duration_min, '')::integer,
       nullif(distance_m, '')::numeric,
       -- Birth year is blank for a large share of trips and occasionally holds
       -- something that is not a year at all; keep only plausible values.
       CASE WHEN birth_year ~ '^\d{4}$'
             AND birth_year::int BETWEEN 1900 AND extract(year FROM now())::int
            THEN birth_year::int END,
       nullif(gender, ''),
       nullif(user_type, ''),
       nullif(start_station_code, ''),
       nullif(end_station_code, '')
FROM bike.trips_raw;

DROP TABLE bike.trips_raw;

CREATE INDEX IF NOT EXISTS trips_started_ix    ON bike.trips (started_at);
CREATE INDEX IF NOT EXISTS trips_start_stn_ix  ON bike.trips (start_station_id);
CREATE INDEX IF NOT EXISTS trips_end_stn_ix    ON bike.trips (end_station_id);
ANALYZE bike.trips;
SQL

psql_c -c "
SELECT count(*)                                   AS trips,
       to_char(min(started_at), 'YYYY-MM-DD')     AS first_day,
       to_char(max(started_at), 'YYYY-MM-DD')     AS last_day,
       count(DISTINCT start_station_id)           AS start_stations,
       pg_size_pretty(pg_total_relation_size('bike.trips')) AS size
FROM bike.trips;"

echo "OK: trips loaded."
