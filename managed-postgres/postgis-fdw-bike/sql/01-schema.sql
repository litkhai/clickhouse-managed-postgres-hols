-- Seoul public bike: geometry in PostGIS, trip facts alongside it.
--
-- The split this lab is built around: stations carry the geometry and stay in
-- Postgres, because that is where the spatial work belongs. Trips are the fact
-- table — the thing that grows without bound and only ever gets aggregated —
-- so it is the side that later moves behind pg_clickhouse. Keeping the columns
-- faithful to the source CSV here means the ClickHouse table can mirror them
-- one-for-one when that happens.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS bike;

-- 대여소 — the geometry side. ~2,800 rows, effectively static.
DROP TABLE IF EXISTS bike.stations CASCADE;
CREATE TABLE bike.stations (
    station_id  integer PRIMARY KEY,          -- 대여소번호
    name        text    NOT NULL,             -- 보관소(대여소)명
    district    text,                         -- 자치구
    address     text,                         -- 상세주소
    lat         double precision,
    lon         double precision,
    racks       integer,                      -- 거치대수
    geom        geometry(Point, 4326)         -- built from lat/lon on load
);

-- 대여이력 — the fact side. ~1.6M rows per month.
DROP TABLE IF EXISTS bike.trips CASCADE;
CREATE TABLE bike.trips (
    -- A surrogate key, because the source has no natural one. Checked: even all
    -- five of bike_id, both timestamps and both station ids leave 96 rows
    -- non-unique — they are real, distinct trips that differ only in the
    -- distance the system recorded.
    --
    -- It is not decoration. Logical replication needs a replica identity, and
    -- without a primary key ClickPipes refuses the table outright. It also
    -- gives the ClickHouse side a sensible key to order and deduplicate on.
    trip_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bike_id            text,                  -- 자전거번호
    -- UTC. The source publishes Korean local time and this column carries no
    -- zone, so the distinction lives here and nowhere else: ClickHouse attaches
    -- a timezone to DateTime, and KST wall-clock arriving there would silently
    -- mean nine hours earlier. load-trips.sh converts on the way in.
    started_at         timestamp,             -- 대여일시 (UTC)
    start_station_id   integer,               -- 대여 대여소번호
    start_station_name text,                  -- 대여 대여소명
    start_rack         integer,               -- 대여거치대
    ended_at           timestamp,             -- 반납일시 (UTC)
    end_station_id     integer,               -- 반납대여소번호
    end_station_name   text,                  -- 반납대여소명
    end_rack           integer,               -- 반납거치대
    duration_min       integer,               -- 이용시간(분)
    distance_m         numeric(12,2),         -- 이용거리(M)
    birth_year         integer,               -- 생년
    gender             text,                  -- 성별
    user_type          text,                  -- 이용자종류
    start_station_code text,                  -- 대여대여소ID  (ST-1461)
    end_station_code   text                   -- 반납대여소ID
);

-- No foreign key from trips to stations on purpose. The history contains
-- station numbers that are not in the current master — stations get retired,
-- and the master is a snapshot — so a constraint would reject real rows.
-- 02-verify.sql reports how many, rather than hiding them.
