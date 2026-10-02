-- Lab 04 — Escape hatch: clickhouse_query() and clickhouse_perform() send arbitrary SQL to ClickHouse
-- clickhouse_query(server, sql) returns rows (needs a column definition list); CALL clickhouse_perform(server, sql) returns nothing.
-- This is how you create CH-native objects (dictionaries, materialized views, etc.) from PG.
-- Both connect with the foreign server's own options and the current user mapping.

\echo '========== 1. SELECT via clickhouse_query =========='

SELECT * FROM clickhouse_query('ch_srv', 'SELECT version()') AS t(clickhouse_version text);

\echo ''
\echo '========== 2. DDL and INSERT via clickhouse_perform (CREATE TABLE in CH) =========='

-- Idempotency: drop dictionary first (it depends on country_lookup), then table.
CALL clickhouse_perform('ch_srv', $$
    DROP DICTIONARY IF EXISTS lab.country_dict
$$);

CALL clickhouse_perform('ch_srv', $$
    DROP TABLE IF EXISTS lab.country_lookup
$$);

CALL clickhouse_perform('ch_srv', $$
    CREATE TABLE lab.country_lookup
    (
        country_code String,
        country_name String,
        continent    String
    ) ENGINE = MergeTree() ORDER BY country_code
$$);

CALL clickhouse_perform('ch_srv', $$
    INSERT INTO lab.country_lookup VALUES
        ('US', 'United States',  'North America'),
        ('KR', 'South Korea',    'Asia'),
        ('JP', 'Japan',          'Asia'),
        ('DE', 'Germany',        'Europe'),
        ('BR', 'Brazil',         'South America')
$$);

\echo ''
\echo '========== 3. Map the new CH table back into PG =========='

DROP FOREIGN TABLE IF EXISTS imported_lab.country_lookup;
CREATE FOREIGN TABLE imported_lab.country_lookup (
    country_code text,
    country_name text,
    continent    text
) SERVER ch_srv OPTIONS (database 'lab', table_name 'country_lookup');

SELECT * FROM imported_lab.country_lookup ORDER BY country_code;

\echo ''
\echo '========== 4. JOIN across users + country_lookup (both in CH) =========='

EXPLAIN (VERBOSE)
SELECT cl.continent,
       u.tier,
       count(*) AS users
FROM   imported_lab.users         u
JOIN   imported_lab.country_lookup cl ON cl.country_code = u.country
GROUP  BY cl.continent, u.tier
ORDER  BY cl.continent, u.tier;

SELECT cl.continent,
       u.tier,
       count(*) AS users
FROM   imported_lab.users         u
JOIN   imported_lab.country_lookup cl ON cl.country_code = u.country
GROUP  BY cl.continent, u.tier
ORDER  BY cl.continent, u.tier;

\echo ''
\echo '========== 5. Create a CH DICTIONARY via clickhouse_perform (and use dictGet pushdown) =========='

CALL clickhouse_perform('ch_srv', $$
    DROP DICTIONARY IF EXISTS lab.country_dict
$$);

CALL clickhouse_perform('ch_srv', $$
    CREATE DICTIONARY lab.country_dict
    (
        country_code String,
        country_name String,
        continent    String
    )
    PRIMARY KEY country_code
    SOURCE(CLICKHOUSE(DB 'lab' TABLE 'country_lookup'))
    LAYOUT(HASHED())
    LIFETIME(MIN 0 MAX 0)
$$);

-- Force the dictionary to load
SELECT * FROM clickhouse_query('ch_srv', $$SELECT dictGet('lab.country_dict', 'country_name', 'KR')$$)
    AS t(lookup_kr text);

\echo ''
\echo '========== 6. Use dictGet() from PostgreSQL via pushdown =========='

-- dictGet is in the pushdown allowlist when used in a WHERE filter
-- (the function does not exist locally in PG, so it must be wholly pushed down).
EXPLAIN (VERBOSE)
SELECT user_id, country
FROM   imported_lab.users
WHERE  dictGet('lab.country_dict', 'continent', country) = 'Asia'
ORDER  BY user_id
LIMIT  5;

SELECT user_id, country
FROM   imported_lab.users
WHERE  dictGet('lab.country_dict', 'continent', country) = 'Asia'
ORDER  BY user_id
LIMIT  5;

-- To project dictionary attributes in the SELECT list, wrap the entire query
-- in a clickhouse_query call so PG never tries to evaluate dictGet locally.
SELECT * FROM clickhouse_query('ch_srv', $$SELECT user_id, dictGet('lab.country_dict','country_name',country) AS country_name, dictGet('lab.country_dict','continent',country) AS continent FROM lab.users WHERE tier = 'enterprise' ORDER BY user_id LIMIT 5$$)
    AS t(user_id bigint, country_name text, continent text);

\echo ''
\echo '========== 7. Pushdown of CH-specific aggregates: uniq / quantile =========='

-- These functions are in the pushdown allowlist
EXPLAIN (VERBOSE)
SELECT event_type,
       uniq(user_id)              AS approx_unique_users,
       quantile(amount)           AS p50_amount
FROM   imported_lab.events
GROUP  BY event_type
ORDER  BY event_type;

SELECT event_type,
       uniq(user_id)              AS approx_unique_users,
       quantile(amount)           AS p50_amount
FROM   imported_lab.events
GROUP  BY event_type
ORDER  BY event_type;

\echo ''
\echo '========== 8. Safety note =========='
\echo '  PUBLIC has no EXECUTE on clickhouse_query() or clickhouse_perform() by default —'
\echo '  superusers can call them; grant explicitly, and only to roles that legitimately'
\echo '  need ad-hoc CH access. Example:'
\echo '    GRANT EXECUTE ON FUNCTION clickhouse_query(text, text) TO data_engineer;'
\echo '    GRANT EXECUTE ON PROCEDURE clickhouse_perform(text, text) TO data_engineer;'

\echo ''
\echo '========== Lab 04 complete =========='
\echo 'You have now: installed the extension, mapped tables, observed pushdown,'
\echo 'and used the clickhouse_query / clickhouse_perform escape hatch. See README.md for further reading.'
