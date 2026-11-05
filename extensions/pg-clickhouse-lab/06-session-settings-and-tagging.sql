-- Lab 06 — pg_clickhouse.session_settings replaces its defaults; tag jobs with log_comment;
-- what a read-only ClickHouse user can do. Needs step 05.

\echo '========== 1. One item, three unmerged versions =========='

-- A table of its own, so the result does not depend on when ClickHouse merges retl.item_scores.
-- SYSTEM STOP MERGES keeps the three INSERTs as three parts.
CALL clickhouse_perform('ch_srv', 'DROP TABLE IF EXISTS retl.versions_demo SYNC');
CALL clickhouse_perform('ch_srv', $$
    CREATE TABLE retl.versions_demo (item_id Int64, score Float64, updated_at DateTime64(3, 'UTC'))
    ENGINE = ReplacingMergeTree(updated_at) ORDER BY item_id$$);
CALL clickhouse_perform('ch_srv', 'SYSTEM STOP MERGES retl.versions_demo');
CALL clickhouse_perform('ch_srv', $$INSERT INTO retl.versions_demo VALUES (1, 0.1, now64(3, 'UTC') - INTERVAL 30 MINUTE)$$);
CALL clickhouse_perform('ch_srv', $$INSERT INTO retl.versions_demo VALUES (1, 0.2, now64(3, 'UTC') - INTERVAL 20 MINUTE)$$);
CALL clickhouse_perform('ch_srv', $$INSERT INTO retl.versions_demo VALUES (1, 0.3, now64(3, 'UTC') - INTERVAL 10 MINUTE)$$);

SELECT * FROM clickhouse_query('ch_srv',
    $$SELECT count() FROM system.parts WHERE database = 'retl' AND table = 'versions_demo' AND active$$)
    AS t(active_parts bigint);

DROP FOREIGN TABLE IF EXISTS ch.versions_demo;
IMPORT FOREIGN SCHEMA retl LIMIT TO (versions_demo) FROM SERVER ch_srv INTO ch;

\echo ''
\echo '========== 2. Defaults, a setting that drops them, and defaults kept =========='

RESET pg_clickhouse.session_settings;
SHOW pg_clickhouse.session_settings;
SELECT 'defaults' AS session_settings, count(*) AS rows_for_item_1, max(score) AS score
FROM   ch.versions_demo WHERE item_id = 1;

-- Adding one setting this way replaces the whole list: final 1 is gone.
SET pg_clickhouse.session_settings = 'log_comment retl_demo';
SELECT 'log_comment only' AS session_settings, count(*) AS rows_for_item_1, max(score) AS score
FROM   ch.versions_demo WHERE item_id = 1;

-- Keep the four defaults and append the tag.
SET pg_clickhouse.session_settings =
    'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, log_comment retl_demo';
SELECT 'defaults + log_comment' AS session_settings, count(*) AS rows_for_item_1, max(score) AS score
FROM   ch.versions_demo WHERE item_id = 1;

-- The Remote SQL has no FINAL keyword; FINAL comes from the final setting.
EXPLAIN (VERBOSE) SELECT count(*) FROM ch.versions_demo WHERE item_id = 1;

RESET pg_clickhouse.session_settings;

\echo ''
\echo '========== 3. Read-only ClickHouse users =========='

DROP SERVER IF EXISTS ch_ro1 CASCADE;
DROP SERVER IF EXISTS ch_ro2 CASCADE;
CREATE SERVER ch_ro1 FOREIGN DATA WRAPPER clickhouse_fdw OPTIONS (driver 'binary', host 'clickhouse', port '9000', dbname 'retl');
CREATE SERVER ch_ro2 FOREIGN DATA WRAPPER clickhouse_fdw OPTIONS (driver 'binary', host 'clickhouse', port '9000', dbname 'retl');
CREATE USER MAPPING FOR CURRENT_USER SERVER ch_ro1 OPTIONS (user 'retl_ro1');
CREATE USER MAPPING FOR CURRENT_USER SERVER ch_ro2 OPTIONS (user 'retl_ro2');

DROP SCHEMA IF EXISTS ch_ro1 CASCADE;
DROP SCHEMA IF EXISTS ch_ro2 CASCADE;
CREATE SCHEMA ch_ro1;
CREATE SCHEMA ch_ro2;

\echo '-- readonly = 1: IMPORT FOREIGN SCHEMA already fails (expect an ERROR)'
IMPORT FOREIGN SCHEMA retl LIMIT TO (versions_demo) FROM SERVER ch_ro1 INTO ch_ro1;

CREATE FOREIGN TABLE ch_ro1.versions_demo (item_id bigint NOT NULL, score float8 NOT NULL, updated_at timestamptz(3) NOT NULL)
    SERVER ch_ro1 OPTIONS (table_name 'versions_demo');

\echo '-- readonly = 1 with the default session_settings (expect an ERROR)'
SELECT count(*) FROM ch_ro1.versions_demo WHERE item_id = 1;

\echo '-- readonly = 1 with session_settings emptied (expect an ERROR: pg_clickhouse sends settings of its own)'
SET pg_clickhouse.session_settings = '';
SELECT count(*) FROM ch_ro1.versions_demo WHERE item_id = 1;
RESET pg_clickhouse.session_settings;

\echo '-- readonly = 2 with defaults + log_comment: works'
IMPORT FOREIGN SCHEMA retl LIMIT TO (versions_demo) FROM SERVER ch_ro2 INTO ch_ro2;
SET pg_clickhouse.session_settings =
    'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, log_comment retl_demo_ro2';
SELECT 'readonly = 2' AS clickhouse_user, count(*) AS rows_for_item_1 FROM ch_ro2.versions_demo WHERE item_id = 1;
RESET pg_clickhouse.session_settings;

\echo '-- readonly = 2 still refuses writes, even with an INSERT grant (expect an ERROR)'
CALL clickhouse_perform('ch_srv', 'GRANT INSERT ON retl.versions_demo TO retl_ro2');
CALL clickhouse_perform('ch_ro2', $$INSERT INTO retl.versions_demo VALUES (2, 0, now64(3, 'UTC'))$$);
CALL clickhouse_perform('ch_srv', 'REVOKE INSERT ON retl.versions_demo FROM retl_ro2');

\echo ''
\echo '========== Lab 06 SQL complete (the runner continues with a fresh session) =========='
