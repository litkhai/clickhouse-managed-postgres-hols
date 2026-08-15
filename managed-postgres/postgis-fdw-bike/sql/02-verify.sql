-- What actually landed, and where the data disagrees with itself.
--
--   ./scripts/psql.sh -f sql/02-verify.sql
--
-- Nothing here is cosmetic: each query answers a question that changed how the
-- schema is built, and re-running it after loading more months keeps those
-- answers honest.

\echo '── stations ───────────────────────────────────────'
SELECT count(*)                 AS stations,
       count(DISTINCT district) AS districts,
       count(*) FILTER (WHERE geom IS NULL) AS without_geometry,
       round(ST_YMin(ST_Extent(geom))::numeric, 4) || ' .. ' ||
       round(ST_YMax(ST_Extent(geom))::numeric, 4) AS lat_range,
       round(ST_XMin(ST_Extent(geom))::numeric, 4) || ' .. ' ||
       round(ST_XMax(ST_Extent(geom))::numeric, 4) AS lon_range
FROM bike.stations;

\echo ''
\echo '── trips ──────────────────────────────────────────'
SELECT count(*)                                       AS trips,
       to_char(min(started_at), 'YYYY-MM-DD')         AS first_day,
       to_char(max(started_at), 'YYYY-MM-DD')         AS last_day,
       count(DISTINCT start_station_id)               AS origin_stations,
       pg_size_pretty(pg_total_relation_size('bike.trips')) AS size
FROM bike.trips;

\echo ''
\echo '── stations in the history that the master does not list ──'
-- Why bike.trips has no foreign key to bike.stations. These are real trips
-- from stations that have since been retired; a constraint would reject them.
SELECT count(*) AS unknown_station_ids,
       (SELECT count(*) FROM bike.trips t
        WHERE NOT EXISTS (SELECT 1 FROM bike.stations s WHERE s.station_id = t.start_station_id)
           OR NOT EXISTS (SELECT 1 FROM bike.stations s WHERE s.station_id = t.end_station_id)
       ) AS trips_affected
FROM (
    SELECT start_station_id AS id FROM bike.trips
    UNION
    SELECT end_station_id   FROM bike.trips
) u
WHERE id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM bike.stations s WHERE s.station_id = u.id);

\echo ''
\echo '── rows that would break a naive load ─────────────'
SELECT count(*) FILTER (WHERE ended_at < started_at)        AS ends_before_start,
       count(*) FILTER (WHERE duration_min = 0)             AS zero_duration,
       count(*) FILTER (WHERE distance_m = 0)               AS zero_distance,
       count(*) FILTER (WHERE start_station_id = end_station_id) AS round_trips,
       count(*) FILTER (WHERE birth_year IS NULL)           AS no_birth_year
FROM bike.trips;

\echo ''
\echo '── the spatial join, by district ──────────────────'
-- The aggregate that belongs in ClickHouse; the ST_Distance that does not.
SELECT s.district,
       count(*)                       AS departures,
       round(avg(t.duration_min), 1)  AS avg_min,
       round(avg(ST_Distance(s.geom::geography, e.geom::geography))::numeric) AS avg_crow_m
FROM bike.trips t
JOIN bike.stations s ON s.station_id = t.start_station_id
JOIN bike.stations e ON e.station_id = t.end_station_id
GROUP BY s.district
ORDER BY departures DESC
LIMIT 10;
