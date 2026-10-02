-- Lab 01 — Install pg_clickhouse, create FOREIGN SERVER and USER MAPPING
-- All statements run inside the lab PostgreSQL container.

\echo '========== 1. Install the pg_clickhouse extension =========='

CREATE EXTENSION IF NOT EXISTS pg_clickhouse;

SELECT extname, extversion, extnamespace::regnamespace AS schema
FROM   pg_extension
WHERE  extname = 'pg_clickhouse';

\echo ''
\echo '========== 2. Available Foreign Data Wrappers =========='

SELECT fdwname, fdwhandler::regproc AS handler, fdwvalidator::regproc AS validator
FROM   pg_foreign_data_wrapper;

\echo ''
\echo '========== 3. Create a FOREIGN SERVER (driver=binary) =========='

DROP SERVER IF EXISTS ch_srv CASCADE;

CREATE SERVER ch_srv
    FOREIGN DATA WRAPPER clickhouse_fdw
    OPTIONS (
        driver 'binary',          -- "binary" (TCP native, port 9000) or "http" (port 8123)
        host   'clickhouse',      -- docker-compose service name
        port   '9000',
        dbname 'default'
    );

SELECT srvname,
       srvowner::regrole  AS owner,
       fdwname           AS wrapper,
       srvoptions
FROM   pg_foreign_server s
JOIN   pg_foreign_data_wrapper f ON f.oid = s.srvfdw
WHERE  srvname = 'ch_srv';

\echo ''
\echo '========== 4. Create a USER MAPPING =========='

CREATE USER MAPPING FOR CURRENT_USER
    SERVER ch_srv
    OPTIONS (user 'default', password '');

SELECT u.usename, u.srvname, u.umoptions
FROM   pg_user_mappings u
WHERE  u.srvname = 'ch_srv';

\echo ''
\echo '========== 5. Sanity check via clickhouse_server_version / clickhouse_query =========='

-- Both functions connect through the foreign server's own driver (binary, port 9000)
-- using the server options and the current user mapping, not a connection string.
SELECT clickhouse_server_version('ch_srv') AS clickhouse_version;

-- And a tiny aggregate against the bounded numbers() table function;
-- clickhouse_query returns SETOF record, so it needs a column definition list.
SELECT * FROM clickhouse_query('ch_srv', 'SELECT count() FROM numbers(1000)')
    AS t(numbers_count bigint);

\echo ''
\echo '========== 6. Inspect type-mapping reference =========='

-- Functions provided by the extension
SELECT proname, p.prokind, pg_get_function_result(p.oid) AS returns
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  p.proname LIKE 'clickhouse_%'
ORDER  BY proname;

\echo ''
\echo '========== Lab 01 complete =========='
\echo 'Next: ./02-import-foreign-schema.sh'
