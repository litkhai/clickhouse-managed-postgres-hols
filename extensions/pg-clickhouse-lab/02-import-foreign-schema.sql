-- Lab 02 — Bring ClickHouse tables into PostgreSQL via IMPORT FOREIGN SCHEMA

\echo '========== 1. Prepare local schemas =========='

CREATE SCHEMA IF NOT EXISTS imported_lab;

-- Drop any prior foreign tables so this script is idempotent
DROP FOREIGN TABLE IF EXISTS imported_lab.events CASCADE;
DROP FOREIGN TABLE IF EXISTS imported_lab.users  CASCADE;

\echo ''
\echo '========== 2. IMPORT FOREIGN SCHEMA =========='

-- This creates one PostgreSQL FOREIGN TABLE for every table in CH database "lab"
IMPORT FOREIGN SCHEMA lab
    FROM SERVER ch_srv
    INTO imported_lab;

\echo ''
\echo '========== 3. Inspect the imported objects =========='

SELECT foreign_table_schema, foreign_table_name
FROM   information_schema.foreign_tables
WHERE  foreign_table_schema = 'imported_lab'
ORDER  BY foreign_table_name;

SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_schema = 'imported_lab' AND table_name = 'events'
ORDER  BY ordinal_position;

\echo ''
\echo '========== 4. Row counts (executed remotely on ClickHouse) =========='

SELECT 'events' AS table_name, count(*) AS rows FROM imported_lab.events
UNION ALL
SELECT 'users'  AS table_name, count(*) AS rows FROM imported_lab.users
ORDER BY table_name;

\echo ''
\echo '========== 5. Browse a few rows =========='

SELECT * FROM imported_lab.events ORDER BY event_id LIMIT 5;
SELECT * FROM imported_lab.users  ORDER BY user_id  LIMIT 5;

\echo ''
\echo '========== 6. Variants of IMPORT FOREIGN SCHEMA =========='

\echo '  -- LIMIT TO (only specific tables):'
\echo '  IMPORT FOREIGN SCHEMA lab LIMIT TO (events) FROM SERVER ch_srv INTO imported_lab;'

\echo '  -- EXCEPT (skip specific tables):'
\echo '  IMPORT FOREIGN SCHEMA lab EXCEPT (users)   FROM SERVER ch_srv INTO imported_lab;'

\echo ''
\echo '========== 7. Type mapping summary =========='
\echo '  ClickHouse type    →  PostgreSQL type'
\echo '  ---------------------+--------------------'
\echo '  UInt64               →  bigint  (errors on overflow)'
\echo '  UInt32               →  bigint'
\echo '  UInt8 / UInt16       →  smallint / integer'
\echo '  Int8 / Int16         →  smallint'
\echo '  Int32 / Int64        →  integer / bigint'
\echo '  Float32 / Float64    →  real    / double precision'
\echo '  Decimal(p,s)         →  numeric(p,s)'
\echo '  Date / Date32        →  date'
\echo '  DateTime / DateTime64→  timestamptz'
\echo '  String               →  text    (or bytea for binary)'
\echo '  LowCardinality(T)    →  same as T'
\echo '  UUID                 →  uuid'
\echo '  IPv4 / IPv6          →  inet'
\echo '  Bool                 →  boolean'
\echo '  JSON                 →  jsonb / json'

\echo ''
\echo '========== Lab 02 complete =========='
\echo 'Next: ./03-pushdown-and-aggregates.sh'
