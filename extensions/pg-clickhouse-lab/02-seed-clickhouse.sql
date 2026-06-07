-- Lab 02 — Seed data inside the ClickHouse container
-- Two tables: lab.events (100k rows) and lab.users (1k rows)

CREATE DATABASE IF NOT EXISTS lab;

DROP TABLE IF EXISTS lab.events;
CREATE TABLE lab.events (
    event_id   UInt64,
    user_id    UInt32,
    event_type LowCardinality(String),
    event_time DateTime,
    amount     Decimal(10, 2)
) ENGINE = MergeTree()
ORDER BY (event_time, event_id);

INSERT INTO lab.events
SELECT
    number                                                                   AS event_id,
    (number % 1000) + 1                                                      AS user_id,
    arrayElement(['click', 'view', 'purchase', 'signup', 'logout'],
                  1 + (number % 5))                                          AS event_type,
    toDateTime('2026-01-01') + INTERVAL (number % 86400) SECOND              AS event_time,
    round((number % 1000) * 0.05, 2)                                         AS amount
FROM numbers(100000);

DROP TABLE IF EXISTS lab.users;
CREATE TABLE lab.users (
    user_id     UInt32,
    country     LowCardinality(String),
    tier        LowCardinality(String),
    signup_date Date
) ENGINE = MergeTree()
ORDER BY user_id;

INSERT INTO lab.users
SELECT
    number + 1                                                AS user_id,
    arrayElement(['US', 'KR', 'JP', 'DE', 'BR'],
                  1 + (number % 5))                           AS country,
    arrayElement(['free', 'pro', 'enterprise'],
                  1 + (number % 3))                           AS tier,
    toDate('2025-01-01') + INTERVAL (number % 365) DAY        AS signup_date
FROM numbers(1000);

SELECT 'events' AS table, count() AS rows FROM lab.events
UNION ALL
SELECT 'users'  AS table, count() AS rows FROM lab.users
ORDER BY table;
