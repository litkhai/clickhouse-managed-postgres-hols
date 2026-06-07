-- Lab 04 — Escape hatch: clickhouse_raw_query() lets you send arbitrary SQL to ClickHouse
-- This is how you create CH-native objects (dictionaries, materialized views, etc.) from PG.

\echo '========== 1. SELECT via raw HTTP =========='

SELECT trim(clickhouse_raw_query(
    'SELECT version()',
    'host=clickhouse port=8123'
)) AS clickhouse_version;

\echo ''
\echo '========== 2. DDL via raw query (CREATE TABLE in CH) =========='

-- Idempotency: drop dictionary first (it depends on country_lookup), then table.
SELECT clickhouse_raw_query($$
    DROP DICTIONARY IF EXISTS lab.country_dict
$$, 'host=clickhouse port=8123');

SELECT clickhouse_raw_query($$
    DROP TABLE IF EXISTS lab.country_lookup
$$, 'host=clickhouse port=8123');

SELECT clickhouse_raw_query($$
    CREATE TABLE lab.country_lookup
    (
        country_code String,
        country_name String,
        continent    String
    ) ENGINE = MergeTree() ORDER BY country_code
$$, 'host=clickhouse port=8123');

SELECT clickhouse_raw_query($$
    INSERT INTO lab.country_lookup VALUES
        ('US', 'United States',  'North America'),
        ('KR', 'South Korea',    'Asia'),
        ('JP', 'Japan',          'Asia'),
        ('DE', 'Germany',        'Europe'),
        ('BR', 'Brazil',         'South America')
$$, 'host=clickhouse port=8123');

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
\echo '========== 5. Create a CH DICTIONARY via raw_query (and use dictGet pushdown) =========='

SELECT clickhouse_raw_query($$
    DROP DICTIONARY IF EXISTS lab.country_dict
$$, 'host=clickhouse port=8123');

SELECT clickhouse_raw_query($$
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
$$, 'host=clickhouse port=8123');

-- Force the dictionary to load
SELECT trim(clickhouse_raw_query(
    'SELECT dictGet(''lab.country_dict'', ''country_name'', ''KR'')',
    'host=clickhouse port=8123'
)) AS lookup_KR;

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
-- in a clickhouse_raw_query call so PG never tries to evaluate dictGet locally.
SELECT trim(clickhouse_raw_query($$
    SELECT toString(user_id) || ' -> ' || dictGet('lab.country_dict', 'country_name', country) || ' (' ||
           dictGet('lab.country_dict', 'continent', country) || ')'
    FROM   lab.users
    WHERE  tier = 'enterprise'
    ORDER  BY user_id
    LIMIT  5
    FORMAT TSV
$$, 'host=clickhouse port=8123')) AS dict_projected;

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
\echo '  clickhouse_raw_query() has NO EXECUTE privileges by default — only superusers'
\echo '  can call it. GRANT EXECUTE only to roles that legitimately need ad-hoc CH access.'
\echo '  Example:'
\echo '    GRANT EXECUTE ON FUNCTION clickhouse_raw_query(text, text) TO data_engineer;'

\echo ''
\echo '========== Lab 04 complete =========='
\echo 'You have now: installed the extension, mapped tables, observed pushdown,'
\echo 'and used the raw-query escape hatch. See README.md for further reading.'
