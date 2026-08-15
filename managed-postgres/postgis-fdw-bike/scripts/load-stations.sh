#!/usr/bin/env bash
# Load the station master into PostGIS. ~2,800 rows; seconds.
#
#   ./scripts/load-stations.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"

[ -s data/stations.xlsx ] || { echo "run ./scripts/fetch-data.sh first" >&2; exit 1; }

echo "target : $(mask_host)"
echo

echo "── schema ─────────────────────────────────────────"
psql_stdin < sql/01-schema.sql
echo "  bike.stations, bike.trips created"

echo
echo "── stations ───────────────────────────────────────"
# Stream the spreadsheet straight into COPY: no intermediate file, so nothing
# with real data is left lying around in the working tree.
python3 scripts/xlsx2csv.py data/stations.xlsx \
  | psql_stdin -c "COPY bike.stations (station_id, name, district, address, lat, lon, racks) FROM STDIN WITH (FORMAT csv, HEADER true)"

psql_stdin <<'SQL'
-- Build the geometry once, then index it. 4326 is what the source publishes
-- (plain WGS84 lat/lon); everything spatial downstream can transform from here.
UPDATE bike.stations SET geom = ST_SetSRID(ST_MakePoint(lon, lat), 4326);
ALTER TABLE bike.stations ALTER COLUMN geom SET NOT NULL;
CREATE INDEX stations_geom_gix ON bike.stations USING GIST (geom);
CREATE INDEX stations_district_ix ON bike.stations (district);
ANALYZE bike.stations;
SQL

psql_c -c "
SELECT count(*)                      AS stations,
       count(DISTINCT district)      AS districts,
       round(ST_XMin(ST_Extent(geom))::numeric, 4) || ' .. ' ||
       round(ST_XMax(ST_Extent(geom))::numeric, 4) AS lon_range,
       round(ST_YMin(ST_Extent(geom))::numeric, 4) || ' .. ' ||
       round(ST_YMax(ST_Extent(geom))::numeric, 4) AS lat_range
FROM bike.stations;"

echo "OK: stations loaded and indexed."
