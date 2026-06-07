-- Lab 03 — Demonstrate that PG-side queries are translated and pushed down to ClickHouse
-- The Remote SQL line in EXPLAIN VERBOSE shows what is actually executed in ClickHouse.

\echo '========== 1. Simple WHERE pushdown =========='

EXPLAIN (VERBOSE)
SELECT event_id, user_id, event_type
FROM   imported_lab.events
WHERE  event_type = 'purchase'
  AND  amount > 30
LIMIT  5;

SELECT event_id, user_id, event_type, amount
FROM   imported_lab.events
WHERE  event_type = 'purchase'
  AND  amount > 30
ORDER  BY event_id
LIMIT  5;

\echo ''
\echo '========== 2. GROUP BY + aggregate pushdown =========='

EXPLAIN (VERBOSE)
SELECT event_type,
       count(*)                    AS hits,
       avg(amount)::numeric(10, 2) AS avg_amt,
       sum(amount)::numeric(12, 2) AS sum_amt
FROM   imported_lab.events
GROUP  BY event_type
ORDER  BY hits DESC;

SELECT event_type,
       count(*)                    AS hits,
       avg(amount)::numeric(10, 2) AS avg_amt,
       sum(amount)::numeric(12, 2) AS sum_amt
FROM   imported_lab.events
GROUP  BY event_type
ORDER  BY hits DESC;

\echo ''
\echo '========== 3. JOIN pushdown =========='

-- Both join inputs live in ClickHouse — the JOIN runs entirely there
EXPLAIN (VERBOSE)
SELECT u.country,
       e.event_type,
       count(*) AS events
FROM   imported_lab.events e
JOIN   imported_lab.users  u  ON u.user_id = e.user_id
WHERE  u.tier = 'enterprise'
GROUP  BY u.country, e.event_type
ORDER  BY u.country, e.event_type;

SELECT u.country,
       e.event_type,
       count(*) AS events
FROM   imported_lab.events e
JOIN   imported_lab.users  u  ON u.user_id = e.user_id
WHERE  u.tier = 'enterprise'
GROUP  BY u.country, e.event_type
ORDER  BY u.country, e.event_type
LIMIT  10;

\echo ''
\echo '========== 4. count(DISTINCT …) =========='

EXPLAIN (VERBOSE)
SELECT event_type, count(DISTINCT user_id) AS unique_users
FROM   imported_lab.events
GROUP  BY event_type
ORDER  BY event_type;

SELECT event_type, count(DISTINCT user_id) AS unique_users
FROM   imported_lab.events
GROUP  BY event_type
ORDER  BY event_type;

\echo ''
\echo '========== 5. Window function pushdown =========='

-- row_number() runs on ClickHouse via the OVER clause
EXPLAIN (VERBOSE)
SELECT event_type,
       event_id,
       amount,
       row_number() OVER (PARTITION BY event_type ORDER BY amount DESC) AS rk
FROM   imported_lab.events
WHERE  amount > 40
ORDER  BY event_type, rk
LIMIT  10;

SELECT event_type,
       event_id,
       amount,
       row_number() OVER (PARTITION BY event_type ORDER BY amount DESC) AS rk
FROM   imported_lab.events
WHERE  amount > 40
ORDER  BY event_type, rk
LIMIT  10;

\echo ''
\echo '========== 6. Date functions are pushed down =========='

-- date_trunc + extract → translated into ClickHouse-native functions
EXPLAIN (VERBOSE)
SELECT date_trunc('hour', event_time) AS bucket,
       count(*)                       AS hits
FROM   imported_lab.events
GROUP  BY bucket
ORDER  BY bucket
LIMIT  10;

SELECT date_trunc('hour', event_time) AS bucket,
       count(*)                       AS hits
FROM   imported_lab.events
GROUP  BY bucket
ORDER  BY bucket
LIMIT  10;

\echo ''
\echo '========== 7. Session settings — forwarded to ClickHouse =========='

-- pg_clickhouse.session_settings forwards arbitrary CH server settings per session.
-- Default is "join_use_nulls 1, group_by_use_nulls 1, final 1".

SHOW pg_clickhouse.session_settings;

SET pg_clickhouse.session_settings = 'connect_timeout 5, max_block_size 8192';
SHOW pg_clickhouse.session_settings;

-- Reset to default
RESET pg_clickhouse.session_settings;

\echo ''
\echo '========== Lab 03 complete =========='
\echo 'Next: ./04-raw-query-and-dictionary.sh'
