-- Five aggregates that belong on ClickHouse.
--
--   ./scripts/psql.sh -f /sql/20-aggregate-pushdown.sql                 -- local
--   ./scripts/psql.sh -v target=ch_bike -f /sql/20-aggregate-pushdown.sql -- remote
--
-- The tables are referenced unqualified and the schema is chosen by search_path,
-- so the identical file runs against the local tables or against the foreign
-- ones. Run it both ways and compare: that is the demo.
--
-- What can and cannot move
-- ------------------------
-- ClickPipes replicates *both* bike.trips and bike.stations, so ClickHouse has
-- a stations table too, and pg_clickhouse pushes down joins between tables on
-- the same remote server. Naming a station or grouping by district is
-- therefore remote work like the counting; forcing it into Postgres would drag
-- work back for nothing. What breaks pushdown is mixing a local table in.
--
-- What genuinely cannot move is the geometry. `geom` is a PostGIS type with no
-- ClickHouse equivalent, and ST_Distance, Voronoi and DBSCAN have no remote
-- form. Query 2 below needs a real distance, so it joins the *local*
-- bike.stations explicitly and is marked as the boundary case. Everything
-- spatial lives in 10-spatial-postgres.sql.
--
-- Timestamps are UTC. Seoul is UTC+9, so the commute peaks land at 23:00 and
-- 09:00 UTC; the queries convert where a reader would otherwise misread them.
--
-- WHAT PUSHES DOWN IS NOT A PROMISE:  ./scripts/explain-pushdown.sh
-- A Foreign Scan whose Remote SQL carries the GROUP BY and the join pushed
-- down. One that only selects columns, with Aggregate or Hash Join above it,
-- did not — the rows crossed the network to be processed here.

\if :{?target}
\else
  \set target bike
\endif
SET search_path TO :target, public;
\echo 'schema:' :target

\timing on

\echo ''
\echo '════ 1. Which stations are commuter stations ══════════════'
-- Splits the network by behaviour rather than geography. A station whose trips
-- cluster into the two commute peaks serves a different purpose from one that
-- fills up on weekend afternoons, and the label falls out of the ratio.
WITH agg AS (
    SELECT start_station_id                                       AS station_id,
           count(*)                                               AS trips,
           sum(CASE WHEN extract(hour FROM started_at) IN (22, 23, 0)  THEN 1 ELSE 0 END) AS morning_peak,
           sum(CASE WHEN extract(hour FROM started_at) IN (8, 9, 10)   THEN 1 ELSE 0 END) AS evening_peak,
           sum(CASE WHEN extract(dow  FROM started_at) IN (0, 6)       THEN 1 ELSE 0 END) AS weekend,
           avg(duration_min)                                      AS avg_min
    FROM trips
    GROUP BY start_station_id
    HAVING count(*) >= 20000
)
SELECT s.district,
       s.name,
       a.trips,
       round(100.0 * (a.morning_peak + a.evening_peak) / a.trips, 1) AS peak_pct,
       round(100.0 * a.weekend / a.trips, 1)                         AS weekend_pct,
       round(a.avg_min, 1)                                           AS avg_min,
       CASE WHEN 100.0 * (a.morning_peak + a.evening_peak) / a.trips > 45 THEN 'commuter'
            WHEN 100.0 * a.weekend / a.trips > 32                          THEN 'leisure'
            ELSE 'mixed' END                                        AS character
FROM agg a
JOIN stations s ON s.station_id = a.station_id
ORDER BY a.trips DESC
LIMIT 12;

\echo ''
\echo '════ 2. The busiest corridors, end to end ═════════════════'
-- THE BOUNDARY CASE. The aggregate can move; the distance cannot. ST_Distance
-- needs geometry, so this joins the local bike.stations by name — everything
-- above the CTE stays in Postgres, and EXPLAIN will show the Foreign Scan
-- ending at the aggregate.
-- A 2,789 x 2,789 space reduced to the handful of pairs that carry real load,
-- then given names and a distance so the numbers mean something. Same-district
-- pairs are short hops around a subway exit; cross-district pairs are the ones
-- worth putting a rebalancing van on.
WITH agg AS (
    SELECT start_station_id, end_station_id,
           count(*)          AS trips,
           avg(duration_min) AS avg_min,
           avg(distance_m)   AS avg_m
    FROM trips
    WHERE start_station_id <> end_station_id
    GROUP BY start_station_id, end_station_id
    HAVING count(*) >= 5000
)
SELECT s.district || ' → ' || e.district                          AS route,
       s.name                                                     AS origin,
       e.name                                                     AS destination,
       a.trips,
       round(a.avg_min, 1)                                        AS avg_min,
       round(ST_Distance(s.geom::geography, e.geom::geography))   AS crow_m,
       round((a.avg_m / nullif(ST_Distance(s.geom::geography, e.geom::geography), 0))::numeric, 2) AS detour,
       CASE WHEN s.district = e.district THEN 'local' ELSE 'crosses districts' END AS kind
FROM agg a
JOIN bike.stations s ON s.station_id = a.start_station_id
JOIN bike.stations e ON e.station_id = a.end_station_id
ORDER BY a.trips DESC
LIMIT 12;

\echo ''
\echo '════ 3. Where rebalancing vans are actually needed ════════'
-- Arrivals minus departures, per station per day. A station that drains every
-- morning and refills every evening nets to zero over a month and needs a van
-- twice a day; the daily spread says that, the monthly total hides it.
WITH movements AS (
    SELECT start_station_id AS station_id, started_at::date AS day,
           count(*) AS out_trips, 0::bigint AS in_trips
    FROM trips GROUP BY 1, 2
    UNION ALL
    SELECT end_station_id, ended_at::date, 0::bigint, count(*)
    FROM trips GROUP BY 1, 2
), agg AS (
    SELECT station_id,
           count(DISTINCT day)                     AS days,
           sum(out_trips)                          AS departures,
           sum(in_trips)                           AS arrivals,
           avg(in_trips - out_trips)               AS avg_daily_net,
           max(abs(in_trips - out_trips))          AS worst_day
    FROM movements
    WHERE station_id IS NOT NULL
    GROUP BY station_id
    HAVING sum(out_trips) + sum(in_trips) >= 40000
)
SELECT s.district,
       s.name,
       a.departures,
       a.arrivals,
       a.arrivals - a.departures                          AS net,
       round(a.avg_daily_net, 1)                          AS avg_daily_net,
       a.worst_day,
       s.racks,
       CASE WHEN a.arrivals - a.departures >  0 THEN 'fills up  (take bikes away)'
            WHEN a.arrivals - a.departures <  0 THEN 'drains    (bring bikes in)'
            ELSE 'balanced' END                           AS pressure
FROM agg a
JOIN stations s ON s.station_id = a.station_id
ORDER BY abs(a.arrivals - a.departures) DESC
LIMIT 12;

\echo ''
\echo '════ 4. How each district rides ═══════════════════════════'
-- Grouping to district needs the stations table, and when both tables are
-- foreign the whole thing — join, group, aggregate — goes over as one remote
-- query. The docs are explicit that JOINs between tables on the same server
-- push down, and equally explicit that joining a *local* table does not:
-- "Joining with a local table will generate less efficient queries without
-- careful tuning." Query 2 is the case where that is unavoidable.
WITH agg AS (
    SELECT start_station_id AS station_id,
           count(*)                                               AS trips,
           avg(duration_min)                                      AS avg_min,
           avg(distance_m)                                        AS avg_m,
           sum(CASE WHEN start_station_id = end_station_id THEN 1 ELSE 0 END) AS round_trips,
           sum(CASE WHEN duration_min >= 60 THEN 1 ELSE 0 END)    AS long_rides,
           sum(CASE WHEN birth_year IS NOT NULL
                     AND extract(year FROM started_at) - birth_year < 30
                    THEN 1 ELSE 0 END)                            AS under_30
    FROM trips
    GROUP BY start_station_id
)
SELECT s.district,
       count(*)                                              AS stations,
       sum(a.trips)                                          AS trips,
       round(sum(a.trips)::numeric / count(*))               AS trips_per_station,
       round(sum(a.avg_min * a.trips) / sum(a.trips), 1)     AS avg_min,
       round(sum(a.avg_m   * a.trips) / sum(a.trips))        AS avg_m,
       round(100.0 * sum(a.round_trips) / sum(a.trips), 1)   AS round_trip_pct,
       round(100.0 * sum(a.long_rides)  / sum(a.trips), 1)   AS over_1h_pct,
       round(100.0 * sum(a.under_30)    / sum(a.trips), 1)   AS under_30_pct
FROM agg a
JOIN stations s ON s.station_id = a.station_id
GROUP BY s.district
ORDER BY trips DESC
LIMIT 12;

\echo ''
\echo '════ 5. When each district wakes up ═══════════════════════'
-- Hour-of-day per station, rolled up to district and converted to Seoul time,
-- because 23:00 UTC being the morning peak is not something a reader should
-- have to hold in their head. Residential districts peak sharply in the
-- morning; districts full of offices peak in the evening.
WITH agg AS (
    SELECT start_station_id                        AS station_id,
           extract(hour FROM started_at)::int      AS utc_hour,
           count(*)                                AS trips
    FROM trips
    WHERE extract(dow FROM started_at) BETWEEN 1 AND 5
    GROUP BY 1, 2
), by_district AS (
    SELECT s.district, a.utc_hour, sum(a.trips) AS trips
    FROM agg a JOIN stations s ON s.station_id = a.station_id
    GROUP BY 1, 2
)
SELECT district,
       sum(trips)                                                       AS weekday_trips,
       (array_agg((utc_hour + 9) % 24 ORDER BY trips DESC))[1]          AS peak_hour_kst,
       round(100.0 * max(trips) / sum(trips), 1)                        AS peak_share_pct,
       round(100.0 * sum(trips) FILTER (WHERE (utc_hour + 9) % 24 BETWEEN 7 AND 9)
             / sum(trips), 1)                                           AS morning_pct,
       round(100.0 * sum(trips) FILTER (WHERE (utc_hour + 9) % 24 BETWEEN 17 AND 19)
             / sum(trips), 1)                                           AS evening_pct,
       CASE WHEN sum(trips) FILTER (WHERE (utc_hour + 9) % 24 BETWEEN 7 AND 9)
               > sum(trips) FILTER (WHERE (utc_hour + 9) % 24 BETWEEN 17 AND 19)
            THEN 'sends commuters out' ELSE 'takes commuters in' END    AS role
FROM by_district
GROUP BY district
ORDER BY weekday_trips DESC
LIMIT 12;
