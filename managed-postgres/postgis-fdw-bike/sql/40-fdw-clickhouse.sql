-- pg_clickhouse: query the ClickHouse copy from Postgres.
--
-- This is the other direction from ClickPipes. ClickPipes replicates Postgres
-- into ClickHouse; nothing it does lets Postgres read back. Aggregate pushdown
-- needs foreign tables on this side, which is what this file creates. Having
-- replication working and having pushdown working are two separate facts, and
-- the UI reports them separately for that reason.
--
--   ./scripts/psql.sh -v ch_host=... -v ch_pass=... -f /sql/40-fdw-clickhouse.sql
--
-- Never commit the host or the password. This repository is public; keep them
-- in the gitignored config.env like every other credential in this lab.

\set ON_ERROR_STOP on

-- The wrapper ships with the service — no CREATE EXTENSION needed beyond this.
CREATE EXTENSION IF NOT EXISTS pg_clickhouse;

-- Options this wrapper accepts, from its own validator:
--   host, secure, min_tls_version, port, dbname, compression, driver, fetch_size
-- ClickHouse Cloud refuses plaintext, so secure must be on; 9440 is the native
-- protocol's TLS port (8443 is the HTTP one, driver 'http').
DROP SERVER IF EXISTS chsrv CASCADE;
CREATE SERVER chsrv FOREIGN DATA WRAPPER clickhouse_fdw
  OPTIONS (host :'ch_host', port '9440', dbname 'pg_sync',
           secure 'true', driver 'binary');

CREATE USER MAPPING FOR CURRENT_USER SERVER chsrv
  OPTIONS (user 'default', password :'ch_pass');

-- A schema of its own, so the same query text can be pointed at either side by
-- changing one identifier. That is what makes the side-by-side on the Pushdown
-- tab a fair comparison rather than two differently written queries.
DROP SCHEMA IF EXISTS ch CASCADE;
CREATE SCHEMA ch;

-- Declared by hand rather than with IMPORT FOREIGN SCHEMA, for one reason:
-- ClickPipes names the tables bike_trips and bike_stations, and the whole point
-- is that `{schema}.trips` runs unchanged against both sides. The table_name
-- option does the renaming.
--
-- The PeerDB bookkeeping columns (_peerdb_synced_at, _peerdb_is_deleted,
-- _peerdb_version) are deliberately left out: they are not part of the model,
-- and a column the query never mentions is one less thing to push down.
CREATE FOREIGN TABLE ch.trips (
    trip_id            bigint,
    bike_id            text,
    started_at         timestamp,
    start_station_id   integer,
    start_station_name text,
    start_rack         integer,
    ended_at           timestamp,
    end_station_id     integer,
    end_station_name   text,
    end_rack           integer,
    duration_min       integer,
    distance_m         numeric(12,2),
    birth_year         integer,
    gender             text,
    user_type          text,
    start_station_code text,
    end_station_code   text
) SERVER chsrv OPTIONS (table_name 'bike_trips');

-- geom comes across as a String because ClickHouse has no geometry type — it is
-- mapped to text here and never selected. Every spatial query in this lab reads
-- bike.stations locally; this copy exists so the *join* can happen remotely.
CREATE FOREIGN TABLE ch.stations (
    station_id integer,
    name       text,
    district   text,
    address    text,
    lat        double precision,
    lon        double precision,
    racks      integer,
    geom       text
) SERVER chsrv OPTIONS (table_name 'bike_stations');

-- Did it work, and is the copy current?
SELECT count(*) AS ch_stations FROM ch.stations;
SELECT count(*) AS ch_trips, max(started_at) AS ch_newest FROM ch.trips;

-- The one that matters. If Remote SQL carries the GROUP BY, ClickHouse counted;
-- if the foreign scan only lists columns and an Aggregate sits above it, every
-- row crossed the network. scripts/explain-pushdown.sh judges this in bulk, and
-- the Pushdown tab in ui/ shows it per query with the row counts.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT s.district, count(*), round(avg(t.duration_min), 1)
FROM ch.trips t JOIN ch.stations s ON s.station_id = t.start_station_id
GROUP BY s.district ORDER BY 2 DESC;
