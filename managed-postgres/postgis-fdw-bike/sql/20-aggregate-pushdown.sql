-- Five aggregate queries meant to run on ClickHouse, not in Postgres.
--
--   ./scripts/psql.sh -f /sql/20-aggregate-pushdown.sql
--
-- Each one reduces ~1.6M trips to at most a few thousand rows using nothing but
-- WHERE, GROUP BY, HAVING, ORDER BY and plain aggregates. That is the subset
-- clickhouse_fdw knows how to translate, so once bike.trips is a foreign table
-- the work happens remotely and only the summary crosses the wire.
--
-- They run against the local table as written, which is how the numbers below
-- were produced. To move them, point the FROM at the foreign table — nothing
-- else changes. Everything spatial is deliberately absent: see
-- 10-spatial-postgres.sql for the half that cannot move.
--
-- WHAT PUSHES DOWN IS NOT A PROMISE. Verify it rather than assuming:
--
--     EXPLAIN (VERBOSE, COSTS OFF) <query>;
--
-- A "Foreign Scan" whose Remote SQL carries the GROUP BY has pushed down. A
-- Foreign Scan that only selects columns, with an Aggregate node above it, has
-- not — Postgres is pulling every row and counting locally, which is worse than
-- leaving the table where it was. Date arithmetic and CASE are the usual things
-- to fall back; if one does, hoist it out of the grouped expression.

\timing on

\echo ''
\echo '════ 1. Hour-of-day profile per station ═══════════════════'
-- 2,789 stations x 24 hours out of 1.6M rows. Conditional sums rather than a
-- pivot, because SUM(CASE ...) is expressible remotely and crosstab is not.
-- Commuter stations show two sharp peaks; leisure stations one broad afternoon.
SELECT start_station_id,
       count(*)                                                                AS trips,
       sum(CASE WHEN extract(hour FROM started_at) BETWEEN  7 AND  9 THEN 1 ELSE 0 END) AS morning,
       sum(CASE WHEN extract(hour FROM started_at) BETWEEN 11 AND 15 THEN 1 ELSE 0 END) AS midday,
       sum(CASE WHEN extract(hour FROM started_at) BETWEEN 17 AND 19 THEN 1 ELSE 0 END) AS evening,
       sum(CASE WHEN extract(hour FROM started_at) BETWEEN  0 AND  4 THEN 1 ELSE 0 END) AS night,
       round(avg(duration_min), 1)                                             AS avg_min
FROM bike.trips
GROUP BY start_station_id
HAVING count(*) >= 2000
ORDER BY (sum(CASE WHEN extract(hour FROM started_at) BETWEEN 7 AND 9 THEN 1 ELSE 0 END)::numeric
          / count(*)) DESC
LIMIT 10;

\echo ''
\echo '════ 2. Heaviest origin-destination pairs ═════════════════'
-- The classic one: a 2,789 x 2,789 space collapsed to the pairs that matter.
-- GROUP BY two columns with a HAVING and a LIMIT is the shape most likely to
-- push down cleanly, which makes it the first thing to check with EXPLAIN.
SELECT start_station_id,
       end_station_id,
       count(*)                    AS trips,
       round(avg(duration_min), 1) AS avg_min,
       round(avg(distance_m))      AS avg_m,
       min(duration_min)           AS fastest_min,
       max(duration_min)           AS slowest_min
FROM bike.trips
WHERE start_station_id <> end_station_id
GROUP BY start_station_id, end_station_id
HAVING count(*) >= 500
ORDER BY trips DESC
LIMIT 10;

\echo ''
\echo '════ 3. Duration distribution by rider type ═══════════════'
-- Bucketing with CASE instead of percentile_cont, which has no remote
-- equivalent and would drag all 1.6M rows back to be sorted locally.
SELECT coalesce(user_type, '(unknown)')                                  AS rider,
       count(*)                                                          AS trips,
       sum(CASE WHEN duration_min <   5 THEN 1 ELSE 0 END)               AS under_5m,
       sum(CASE WHEN duration_min >=  5 AND duration_min < 15 THEN 1 ELSE 0 END) AS m5_15,
       sum(CASE WHEN duration_min >= 15 AND duration_min < 30 THEN 1 ELSE 0 END) AS m15_30,
       sum(CASE WHEN duration_min >= 30 AND duration_min < 60 THEN 1 ELSE 0 END) AS m30_60,
       sum(CASE WHEN duration_min >= 60 THEN 1 ELSE 0 END)               AS over_1h,
       round(avg(duration_min), 1)                                       AS avg_min,
       round(avg(CASE WHEN distance_m > 0 AND duration_min > 0
                      THEN distance_m / duration_min / 1000.0 * 60 END), 1) AS avg_kmh
FROM bike.trips
GROUP BY coalesce(user_type, '(unknown)')
ORDER BY trips DESC;

\echo ''
\echo '════ 4. Daily arrival/departure imbalance per station ═════'
-- Rebalancing is driven by this number. Two passes over the fact table unioned
-- and re-grouped: each half is a plain GROUP BY that can travel, and the union
-- is cheap on the reduced result.
WITH movements AS (
    SELECT start_station_id AS station_id, started_at::date AS day,
           count(*) AS out_trips, 0::bigint AS in_trips
    FROM bike.trips
    GROUP BY start_station_id, started_at::date
    UNION ALL
    SELECT end_station_id, ended_at::date,
           0::bigint, count(*)
    FROM bike.trips
    GROUP BY end_station_id, ended_at::date
)
SELECT station_id,
       -- count(*) here would count union branches, not days: it read 64 for a
       -- 31-day month because departures and arrivals each contribute a row.
       count(DISTINCT day)                         AS days,
       sum(out_trips)                              AS departures,
       sum(in_trips)                               AS arrivals,
       sum(in_trips) - sum(out_trips)              AS net,
       round((sum(in_trips) - sum(out_trips))::numeric
             / count(DISTINCT day), 1)             AS avg_daily_net
FROM movements
WHERE station_id IS NOT NULL
GROUP BY station_id
HAVING sum(out_trips) + sum(in_trips) >= 3000
ORDER BY abs(sum(in_trips) - sum(out_trips)) DESC
LIMIT 10;

\echo ''
\echo '════ 5. Age band x weekday, and how far each rides ════════'
-- A four-way grouping over the whole table, and the one most likely to expose a
-- function that will not translate: extract(dow ...) and the age arithmetic are
-- both computed per row before grouping.
SELECT CASE WHEN birth_year IS NULL THEN '(unknown)'
            WHEN extract(year FROM started_at) - birth_year < 20 THEN 'under 20'
            WHEN extract(year FROM started_at) - birth_year < 30 THEN '20s'
            WHEN extract(year FROM started_at) - birth_year < 40 THEN '30s'
            WHEN extract(year FROM started_at) - birth_year < 50 THEN '40s'
            WHEN extract(year FROM started_at) - birth_year < 65 THEN '50-64'
            ELSE '65+' END                                            AS age_band,
       CASE WHEN extract(dow FROM started_at) IN (0, 6) THEN 'weekend'
            ELSE 'weekday' END                                        AS part_of_week,
       count(*)                                                       AS trips,
       round(avg(duration_min), 1)                                    AS avg_min,
       round(avg(distance_m))                                         AS avg_m,
       sum(CASE WHEN start_station_id = end_station_id THEN 1 ELSE 0 END) AS round_trips,
       round(100.0 * sum(CASE WHEN start_station_id = end_station_id THEN 1 ELSE 0 END)
             / count(*), 1)                                           AS round_trip_pct
FROM bike.trips
GROUP BY 1, 2
ORDER BY age_band, part_of_week;
