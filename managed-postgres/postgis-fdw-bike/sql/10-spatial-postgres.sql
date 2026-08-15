-- Five spatial queries that have to run in Postgres.
--
--   ./scripts/psql.sh -f /sql/10-spatial-postgres.sql
--
-- None of these can be pushed anywhere. They call PostGIS on geometry that has
-- no ClickHouse equivalent, and the planner has no way to express ST_Distance,
-- a Voronoi diagram or a GiST distance-ordered scan as a remote query. That is
-- the point of the split: this half stays put, and only the counting travels.
--
-- Where a query needs trip volumes, it aggregates first and joins the small
-- result to geometry — the same shape the ClickHouse side will take, so these
-- keep working unchanged once bike.trips is a foreign table.

\timing on

\echo ''
\echo '════ 1. Voronoi service areas ═════════════════════════════'
-- Which station "owns" how much ground. ST_VoronoiPolygons produces one cell
-- per station over the whole plane, so it is clipped to the convex hull of the
-- network or the edge stations get unbounded cells. Area is measured on the
-- geography type to get square metres rather than square degrees.
WITH cells AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(ST_Collect(geom)))).geom AS cell
    FROM bike.stations
), hull AS (
    SELECT ST_ConvexHull(ST_Collect(geom)) AS h FROM bike.stations
), owned AS (
    SELECT s.station_id, s.name, s.district,
           ST_Intersection(c.cell, hull.h) AS area_geom
    FROM cells c
    CROSS JOIN hull
    JOIN bike.stations s ON ST_Within(s.geom, c.cell)
), demand AS (
    SELECT start_station_id AS station_id, count(*) AS departures
    FROM bike.trips GROUP BY 1
)
SELECT o.district, o.name,
       round((ST_Area(o.area_geom::geography) / 1000000)::numeric, 3) AS service_km2,
       coalesce(d.departures, 0)                                      AS departures,
       round((coalesce(d.departures, 0) /
              nullif(ST_Area(o.area_geom::geography) / 1000000, 0))::numeric) AS trips_per_km2
FROM owned o
LEFT JOIN demand d USING (station_id)
WHERE ST_Area(o.area_geom::geography) > 0
ORDER BY trips_per_km2 DESC NULLS LAST
LIMIT 10;

\echo ''
\echo '════ 2. Five nearest neighbours per station ═══════════════'
-- The <-> operator with an ORDER BY and a LIMIT inside LATERAL is what makes
-- the GiST index give nearest-neighbour order directly, instead of computing
-- 2,789 x 2,789 distances and sorting. Reported for the ten most isolated
-- stations: the ones whose nearest neighbour is furthest away.
WITH neighbours AS (
    SELECT s.station_id, s.name, s.district,
           n.station_id AS near_id,
           ST_Distance(s.geom::geography, n.geom::geography) AS metres,
           row_number() OVER (PARTITION BY s.station_id ORDER BY s.geom <-> n.geom) AS rank
    FROM bike.stations s
    CROSS JOIN LATERAL (
        SELECT station_id, geom
        FROM bike.stations x
        WHERE x.station_id <> s.station_id
        ORDER BY x.geom <-> s.geom
        LIMIT 5
    ) n
)
SELECT district, name,
       round(min(metres))                              AS nearest_m,
       round(avg(metres))                              AS avg_of_5_m,
       round(max(metres))                              AS fifth_m
FROM neighbours
GROUP BY station_id, district, name
ORDER BY nearest_m DESC
LIMIT 10;

\echo ''
\echo '════ 3. DBSCAN clusters of stations ═══════════════════════'
-- Density-based clustering finds where the network actually thickens, which
-- administrative boundaries do not tell you — a cluster can straddle two
-- districts. eps is in degrees here because ST_ClusterDBSCAN works on the
-- geometry type; 0.0045 is roughly 400m at Seoul's latitude.
WITH clustered AS (
    SELECT station_id, name, district, geom,
           ST_ClusterDBSCAN(geom, eps => 0.0045, minpoints => 5) OVER () AS cluster_id
    FROM bike.stations
), demand AS (
    SELECT start_station_id AS station_id, count(*) AS departures
    FROM bike.trips GROUP BY 1
)
SELECT c.cluster_id,
       count(*)                                                     AS stations,
       count(DISTINCT c.district)                                   AS districts_spanned,
       string_agg(DISTINCT c.district, ', ' ORDER BY c.district)    AS which,
       round((ST_Area(ST_ConvexHull(ST_Collect(c.geom))::geography) / 1000000)::numeric, 2) AS hull_km2,
       sum(coalesce(d.departures, 0))                               AS departures
FROM clustered c
LEFT JOIN demand d USING (station_id)
WHERE c.cluster_id IS NOT NULL
GROUP BY c.cluster_id
ORDER BY departures DESC
LIMIT 10;

\echo ''
\echo '════ 4. Detour factor per origin-destination pair ═════════'
-- The system records a distance per trip. Comparing it to the geodesic
-- straight line between the two stations says how much further riders actually
-- go than they strictly must — and surfaces rows where the recorded distance is
-- shorter than the straight line, which cannot happen and marks bad data.
-- Round trips are excluded: their straight line is zero and the ratio explodes.
WITH pairs AS (
    SELECT start_station_id, end_station_id,
           count(*)          AS trips,
           avg(distance_m)   AS avg_recorded_m,
           avg(duration_min) AS avg_min
    FROM bike.trips
    WHERE start_station_id <> end_station_id
      AND distance_m > 0
    GROUP BY 1, 2
    HAVING count(*) >= 200
)
SELECT s.district                                            AS from_district,
       s.name                                                AS from_station,
       e.name                                                AS to_station,
       p.trips,
       round(ST_Distance(s.geom::geography, e.geom::geography)) AS crow_m,
       round(p.avg_recorded_m)                               AS recorded_m,
       round((p.avg_recorded_m /
              nullif(ST_Distance(s.geom::geography, e.geom::geography), 0))::numeric, 2) AS detour,
       round(p.avg_min, 1)                                   AS avg_min
FROM pairs p
JOIN bike.stations s ON s.station_id = p.start_station_id
JOIN bike.stations e ON e.station_id = p.end_station_id
ORDER BY detour DESC
LIMIT 10;

\echo ''
\echo ''
\echo '════ 5. Net flow and its direction, per district ══════════'
-- ST_Azimuth gives the bearing of each origin-destination line, which turns
-- "where do bikes drift" into something answerable. Net flow is arrivals minus
-- departures.
--
-- Bearings must be averaged as vectors, not as numbers. Averaging them
-- arithmetically makes 350 and 10 come out as 180 — the exact opposite of the
-- true mean — and because flows are roughly symmetric it produced a confident
-- "S" for all 25 districts on the first attempt. Summing the unit vectors and
-- taking atan2 gives the real mean direction, and the length of the resultant
-- says whether there is a dominant direction at all: near 1 is one-way drift,
-- near 0 means the flows cancel and the bearing is noise.
WITH flows AS (
    SELECT start_station_id, end_station_id, count(*) AS trips
    FROM bike.trips
    WHERE start_station_id <> end_station_id
    GROUP BY 1, 2
), directed AS (
    SELECT s.district,
           f.trips,
           ST_Azimuth(s.geom, e.geom) AS bearing_rad,
           ST_Distance(s.geom::geography, e.geom::geography) AS metres
    FROM flows f
    JOIN bike.stations s ON s.station_id = f.start_station_id
    JOIN bike.stations e ON e.station_id = f.end_station_id
), balance AS (
    SELECT s.district,
           sum(CASE WHEN t.start_station_id = s.station_id THEN 1 ELSE 0 END) AS departures,
           sum(CASE WHEN t.end_station_id   = s.station_id THEN 1 ELSE 0 END) AS arrivals
    FROM bike.stations s
    JOIN bike.trips t ON t.start_station_id = s.station_id
                      OR t.end_station_id   = s.station_id
    GROUP BY s.district
), vectors AS (
    SELECT district,
           sum(trips)                        AS trips,
           sum(trips * sin(bearing_rad))     AS x,
           sum(trips * cos(bearing_rad))     AS y,
           sum(trips * metres)               AS trip_metres
    FROM directed GROUP BY district
)
SELECT v.district,
       b.departures,
       b.arrivals,
       b.arrivals - b.departures                                  AS net,
       round((degrees(atan2(v.x, v.y))::numeric + 360) % 360)      AS mean_bearing_deg,
       CASE WHEN sqrt(v.x*v.x + v.y*v.y) / v.trips < 0.05 THEN '-- (cancels out)'
            ELSE (ARRAY['N','NE','E','SE','S','SW','W','NW'])[
                   1 + (((degrees(atan2(v.x, v.y))::numeric + 360) % 360 + 22.5) / 45)::int % 8]
       END                                                        AS heading,
       round((sqrt(v.x*v.x + v.y*v.y) / v.trips)::numeric, 3)     AS concentration,
       round((v.trip_metres / v.trips)::numeric)                  AS mean_hop_m
FROM vectors v
JOIN balance b USING (district)
ORDER BY abs(b.arrivals - b.departures) DESC
LIMIT 10;
