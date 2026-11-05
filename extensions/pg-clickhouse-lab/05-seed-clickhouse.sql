-- Lab 05 (ClickHouse side) — the source of the reverse ETL in steps 05-09.
-- Runs through clickhouse-client inside the lab ClickHouse container.

-- One row per item, versioned by updated_at. ReplacingMergeTree keeps the newest version of each
-- item_id once parts merge; until then a plain SELECT can return several versions of one item.
DROP DATABASE IF EXISTS retl SYNC;
CREATE DATABASE retl;

CREATE TABLE retl.item_scores
(
    item_id    Int64,
    score      Float64,
    labels     Array(String),
    updated_at DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY item_id;

-- Deletes for the delta pattern (step 08): the producer writes a tombstone here
-- and removes the row from retl.item_scores.
CREATE TABLE retl.item_scores_deleted
(
    item_id    Int64,
    deleted_at DateTime64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (deleted_at, item_id);

-- 10,000 items, all written an hour ago.
INSERT INTO retl.item_scores
SELECT number + 1,
       round(number % 1000 / 1000, 3),
       [concat('group-', toString(number % 7))],
       now64(3, 'UTC') - INTERVAL 1 HOUR
FROM numbers(10000);

-- Two ClickHouse users for step 06: readonly = 1 and readonly = 2.
-- retl_ro2 also gets INSERT on one table, to show that readonly (not the grant) refuses the write.
DROP USER IF EXISTS retl_ro1, retl_ro2;
CREATE USER retl_ro1 IDENTIFIED WITH no_password SETTINGS readonly = 1;
CREATE USER retl_ro2 IDENTIFIED WITH no_password SETTINGS readonly = 2;
GRANT SELECT ON retl.* TO retl_ro1, retl_ro2;

SELECT 'retl.item_scores' AS table, count() AS rows FROM retl.item_scores
UNION ALL
SELECT 'retl.item_scores_deleted', count() FROM retl.item_scores_deleted;

SHOW CREATE USER retl_ro1;
SHOW CREATE USER retl_ro2;
