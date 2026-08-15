-- Run the trip generator inside Postgres, on a schedule, with no client.
--
--   ./scripts/psql.sh -f /sql/30-generator-in-db.sql
--   ./scripts/psql.sh -c "SELECT bike.generator_schedule('30 seconds')"
--   ./scripts/psql.sh -c "SELECT bike.generator_unschedule()"
--
-- The shell generator needs a laptop staying awake. This does the same thing
-- server-side: pg_cron calls a procedure that inserts however many trips this
-- hour of this weekday calls for. It keeps running when you close the lid,
-- which is what a demo that should still be moving tomorrow morning needs.
--
-- The model is the same one scripts/tripgen.py uses, and for the same reason:
-- a generated trip is a real trip with a new timestamp, drawn from the pool of
-- real trips that started in the same hour of the same kind of day. Hour of
-- day, origin, destination, duration and rider stay tied together; sampling
-- each column separately would flatten the OD matrix into noise.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- The generator's working tables live in their own schema, not next to
-- bike.trips. CDC only ever wants trips and stations, and a publication
-- declared FOR ALL TABLES would otherwise sweep the sample pool and the
-- weight tables into ClickHouse along with them.
CREATE SCHEMA IF NOT EXISTS bikegen;

-- bike.trips is stored in UTC. The source publishes Korean local time, and
-- scripts/shift-to-utc.sh converted it once: a `timestamp without time zone`
-- carrying KST would arrive in ClickHouse meaning something nine hours off,
-- because ClickHouse attaches a timezone to DateTime and Postgres does not.
--
-- So the model below is built from UTC timestamps and the procedure compares
-- against now() directly. The weekday peaks sit at 23:00 and 09:00 UTC, which
-- are 08 and 18 in Seoul.

-- ── the model, measured from whatever is already loaded ──────────────────────

-- Trips to draw from, bucketed the way they will be drawn. `n` is dense within
-- each bucket so a pick is one random integer and one index lookup.
DROP TABLE IF EXISTS bikegen.gen_pool;
CREATE TABLE bikegen.gen_pool AS
SELECT (extract(dow FROM started_at) IN (0, 6))          AS is_weekend,
       extract(hour FROM started_at)::int                AS hour,
       row_number() OVER (PARTITION BY (extract(dow FROM started_at) IN (0, 6)),
                                       extract(hour FROM started_at)
                          ORDER BY trip_id)              AS n,
       bike_id, start_station_id, start_station_name, start_rack,
       end_station_id, end_station_name, end_rack,
       duration_min, distance_m, birth_year, gender, user_type,
       start_station_code, end_station_code
FROM bike.trips
WHERE start_station_id IS NOT NULL
  AND end_station_id IS NOT NULL
  -- Every 400th trip: enough to cover the OD matrix, small enough that the
  -- pool stays in cache and a pick never touches disk.
  AND mod(trip_id, 400) = 0;

CREATE UNIQUE INDEX gen_pool_pick ON bikegen.gen_pool (is_weekend, hour, n);
ANALYZE bikegen.gen_pool;

-- How many trips are in each bucket, so a pick can pick in range.
DROP TABLE IF EXISTS bikegen.gen_bucket;
CREATE TABLE bikegen.gen_bucket AS
SELECT is_weekend, hour, count(*) AS size FROM bikegen.gen_pool GROUP BY 1, 2;
ALTER TABLE bikegen.gen_bucket ADD PRIMARY KEY (is_weekend, hour);

-- Share of a day's trips falling in each hour. Measured, not assumed: weekdays
-- peak hard at 08 and 18, weekends spread across the afternoon.
DROP TABLE IF EXISTS bikegen.gen_hour_weight;
CREATE TABLE bikegen.gen_hour_weight AS
WITH counted AS (
    SELECT (extract(dow FROM started_at) IN (0, 6)) AS is_weekend,
           extract(hour FROM started_at)::int       AS hour,
           count(*)                                 AS n
    FROM bike.trips GROUP BY 1, 2
)
SELECT is_weekend, hour, n::numeric / sum(n) OVER (PARTITION BY is_weekend) AS weight
FROM counted;
ALTER TABLE bikegen.gen_hour_weight ADD PRIMARY KEY (is_weekend, hour);

-- Trips on an average day of each kind. Edge days are excluded because a
-- partial first or last day would drag the mean down.
DROP TABLE IF EXISTS bikegen.gen_daily_base;
CREATE TABLE bikegen.gen_daily_base AS
WITH per_day AS (
    SELECT started_at::date AS day,
           (extract(dow FROM started_at) IN (0, 6)) AS is_weekend,
           count(*) AS n
    FROM bike.trips GROUP BY 1, 2
)
SELECT is_weekend, avg(n) AS trips_per_day
FROM per_day
WHERE day > (SELECT min(started_at)::date FROM bike.trips)
  AND day < (SELECT max(started_at)::date FROM bike.trips)
GROUP BY 1;
ALTER TABLE bikegen.gen_daily_base ADD PRIMARY KEY (is_weekend);

-- Seasonal factor. Derived from the sizes of the published monthly files
-- (280, 307, 501, 674, 690, 716 MB for 2026-01..06) divided by January's.
-- July onward is extrapolated — those months are not published yet.
DROP TABLE IF EXISTS bikegen.gen_month_scale;
CREATE TABLE bikegen.gen_month_scale (month int PRIMARY KEY, factor numeric, measured boolean);
INSERT INTO bikegen.gen_month_scale VALUES
    (1, 1.00, true), (2, 1.09, true), (3, 1.79, true),
    (4, 2.40, true), (5, 2.46, true), (6, 2.56, true),
    (7, 2.20, false), (8, 2.25, false), (9, 2.50, false),
    (10, 2.45, false), (11, 1.70, false), (12, 1.10, false);

-- ── the generator ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION bikegen.gen_poisson(mean double precision)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE u1 double precision; u2 double precision;
BEGIN
    -- Arrivals vary. Without this every run of the same length inserts exactly
    -- the same number and the feed ticks like a metronome. Above ~30 the
    -- normal approximation to Poisson is indistinguishable and far cheaper
    -- than Knuth's product loop, and these means are in the hundreds.
    IF mean <= 0 THEN RETURN 0; END IF;
    u1 := random(); u2 := random();
    IF u1 = 0 THEN u1 := 1e-9; END IF;
    RETURN greatest(0, round(mean + sqrt(mean) * sqrt(-2 * ln(u1)) * cos(2 * pi() * u2)));
END $$;

CREATE OR REPLACE PROCEDURE bike.generate_trips(
    p_minutes int DEFAULT 1,
    p_scale   numeric DEFAULT 1.0
) LANGUAGE plpgsql AS $$
DECLARE
    -- The table is UTC and the server is UTC, so these line up directly. This
    -- read AT TIME ZONE 'Asia/Seoul' while the data was still KST; getting it
    -- wrong is silent — at 16:45 in Seoul it generated the 07:00 shape and
    -- stamped rows nine hours from every historical row.
    v_now       timestamp := now()::timestamp;
    v_weekend   boolean   := extract(dow FROM v_now) IN (0, 6);
    v_hour      int       := extract(hour FROM v_now)::int;
    v_base      numeric;
    v_weight    numeric;
    v_factor    numeric;
    v_bucket    int;
    v_target    bigint;
BEGIN
    SELECT trips_per_day INTO v_base FROM bikegen.gen_daily_base WHERE is_weekend = v_weekend;
    SELECT weight        INTO v_weight FROM bikegen.gen_hour_weight
        WHERE is_weekend = v_weekend AND hour = v_hour;
    SELECT factor        INTO v_factor FROM bikegen.gen_month_scale
        WHERE month = extract(month FROM v_now)::int;
    SELECT size          INTO v_bucket FROM bikegen.gen_bucket
        WHERE is_weekend = v_weekend AND hour = v_hour;

    IF v_base IS NULL OR v_weight IS NULL OR v_bucket IS NULL OR v_bucket = 0 THEN
        RAISE NOTICE 'bike.generate_trips: no model for %s hour %', v_weekend, v_hour;
        RETURN;
    END IF;

    v_target := bikegen.gen_poisson(
        (v_base * coalesce(v_factor, 1.0) * v_weight * p_scale * p_minutes / 60.0)::double precision);
    IF v_target <= 0 THEN RETURN; END IF;

    -- Draw the pick in a subquery over generate_series, not inside a LATERAL.
    -- random() in a LATERAL's WHERE clause is evaluated once for the whole
    -- statement, so every generated row came back a copy of the same trip:
    -- 407 rows, two distinct trips. In a target list over generate_series it is
    -- volatile per row, which is what this needs.
    INSERT INTO bike.trips (
        bike_id, started_at, start_station_id, start_station_name, start_rack,
        ended_at, end_station_id, end_station_name, end_rack, duration_min,
        distance_m, birth_year, gender, user_type, start_station_code, end_station_code)
    SELECT p.bike_id,
           -- Started far enough back that the trip could have finished, and
           -- spread across the window rather than all on the same second.
           v_now - make_interval(mins => d.jitter, secs => s.offset_secs),
           p.start_station_id, p.start_station_name, p.start_rack,
           v_now - make_interval(secs => s.offset_secs),
           p.end_station_id, p.end_station_name, p.end_rack,
           d.jitter,
           -- Scale distance with duration so the implied speed stays sane.
           CASE WHEN coalesce(p.duration_min, 0) > 0
                THEN round(p.distance_m * d.jitter / p.duration_min, 2)
                ELSE p.distance_m END,
           p.birth_year, p.gender, p.user_type,
           p.start_station_code, p.end_station_code
    FROM (
        SELECT 1 + floor(random() * v_bucket)::int   AS pick,
               floor(random() * p_minutes * 60)::int AS offset_secs,
               0.8 + random() * 0.4                  AS stretch
        FROM generate_series(1, v_target)
    ) s
    JOIN bikegen.gen_pool p
      ON p.is_weekend = v_weekend AND p.hour = v_hour AND p.n = s.pick
    CROSS JOIN LATERAL (
        SELECT greatest(0, round(coalesce(p.duration_min, 0) * s.stretch))::int AS jitter
    ) d;
END $$;

-- ── scheduling ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION bike.generator_schedule(every interval DEFAULT '1 minute')
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_job bigint; v_seconds int := extract(epoch FROM every)::int;
BEGIN
    PERFORM bike.generator_unschedule();
    -- pg_cron takes cron syntax by the minute, or "N seconds" for sub-minute.
    v_job := cron.schedule('bike-generate',
                           CASE WHEN v_seconds < 60 THEN v_seconds || ' seconds'
                                ELSE '*/' || greatest(1, v_seconds / 60) || ' * * * *' END,
                           format('CALL bike.generate_trips(%s, 1.0)',
                                  greatest(1, v_seconds / 60)));
    RETURN v_job;
END $$;

CREATE OR REPLACE FUNCTION bike.generator_unschedule() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM cron.unschedule('bike-generate')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'bike-generate');
END $$;

\echo ''
\echo 'model built. schedule it with:'
\echo "  SELECT bike.generator_schedule('1 minute');"
\echo 'watch it with:'
\echo '  SELECT jobname, schedule, active FROM cron.job;'
\echo '  SELECT status, start_time, return_message FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;'
