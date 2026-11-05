# pg_clickhouse Lab — Query ClickHouse from PostgreSQL

[English](#english) | [한국어](#한국어)

---

## English

> **Related notes** (Korean): [pg_clickhouse — PostgreSQL에서 ClickHouse 사용하기](https://clickhouse.litkhai.dev/articles/feature/pg-clickhouse-postgresql-clickhouse/)

A self-contained lab that needs only Docker. It demonstrates the official **`pg_clickhouse`** PostgreSQL extension end to end.

PostgreSQL 18 with pg_clickhouse 0.11.0 and pg_cron 1.6.8, and ClickHouse 26.9.7.9, run together on a private Docker network. You install the extension, register a foreign server, import schemas, observe pushdown, and send ClickHouse SQL directly with `clickhouse_query()` / `clickhouse_perform()`. Steps 05–09 turn the direction around: a pg_cron job in PostgreSQL pulls ClickHouse results into a local serving table (reverse ETL). Nothing is installed on your host.

### 📋 What is `pg_clickhouse`?

`pg_clickhouse` is an Apache 2.0-licensed PostgreSQL extension published by ClickHouse in December 2025. It lets PostgreSQL clients run analytic queries against ClickHouse **without rewriting any SQL**. The extension parses each query, translates the parts it can, and **pushes them down** to ClickHouse for execution. Only the final result rows come back to PostgreSQL.

- **Repository**: [ClickHouse/pg_clickhouse](https://github.com/ClickHouse/pg_clickhouse)
- **Docs**: [clickhouse.com/docs/integrations/pg_clickhouse](https://clickhouse.com/docs/integrations/pg_clickhouse)
- **PGXN**: [pgxn.org/dist/pg_clickhouse](https://pgxn.org/dist/pg_clickhouse)
- **Pre-built image**: `ghcr.io/clickhouse/pg_clickhouse:<pg-major>-<release>`. Release 0.11.0 is published for PG 14–18 (GHCR tag list, read 2026-10-01). This lab uses `18-0.11.0`.
- **Supports**: PostgreSQL 14+ (0.11 dropped PG 13) and ClickHouse 23.3+
- **License**: Apache-2.0
- **As of Jan 2026** it was the **fastest** PG analytics extension on ClickBench

### 🎯 What this lab covers

| Step | Topic | Highlights |
|---|---|---|
| 01 | Extension + Foreign Server + User Mapping | `CREATE EXTENSION`, `CREATE SERVER`, `CREATE USER MAPPING`, `clickhouse_server_version`, `clickhouse_query` |
| 02 | `IMPORT FOREIGN SCHEMA` | Auto-create PG foreign tables for every CH table; type-mapping table |
| 03 | Pushdown demonstration | `EXPLAIN (VERBOSE)` showing JOIN, GROUP BY and window-function pushdown to CH |
| 04 | `clickhouse_query` / `clickhouse_perform` + dictionaries | Create CH objects from PG, then `dictGet` pushdown |
| 05 | pg_cron + the reverse-ETL source | Preload pg_cron, a new session per run, `IMPORT FOREIGN SCHEMA` of a `ReplacingMergeTree` table |
| 06 | `session_settings`, `log_comment`, read-only users | Replacing the defaults drops `final 1`; tag a job; `readonly = 1` vs `readonly = 2` |
| 07 | Pattern A — full refresh + swap | Rebuild, `ANALYZE`, rename in one transaction every 5 s; a long reader makes the swap fail on `lock_timeout` |
| 08 | Pattern B — delta upsert | Watermark window, `ON CONFLICT`, tombstones; a failing cycle leaves table and watermark unchanged |
| 09 | `system.query_log` correlation | One row per pg_cron run next to its ClickHouse statements; `EXPLAIN ANALYZE` has no query id |

### 🚀 Quick Start

```bash
cd extensions/pg-clickhouse-lab
./00-setup.sh

# Walk through the lab
./01-extension-and-server.sh
./02-import-foreign-schema.sh
./03-pushdown-and-aggregates.sh
./04-raw-query-and-dictionary.sh

# Reverse ETL with pg_cron (in order; 07-09 take about a minute together)
./05-pg-cron.sh
./06-session-settings-and-tagging.sh
./07-refresh-full-swap.sh
./08-refresh-delta-upsert.sh
./09-query-log-correlation.sh

# Interactive shells
./psql.sh                    # psql against pgch-postgres
./clickhouse-client.sh       # clickhouse-client against pgch-clickhouse

# Tear it all down
./cleanup.sh
```

The setup script will:
1. Pull `clickhouse/clickhouse-server:26.9.7.9` and build `pgch-postgres-cron` from [postgres/Dockerfile](postgres/Dockerfile): `ghcr.io/clickhouse/pg_clickhouse:18-0.11.0` plus the PGDG package `postgresql-18-cron` 1.6.8. The ClickHouse image and the base image are pinned by multi-arch digest, the package by version; see [STATUS.md](../../STATUS.md) for why. The build needs network access to the PGDG apt repository.
2. Start them on a private bridge network (`pgch_net`), with `shared_preload_libraries=pg_cron` on the postgres command line
3. Wait for both to be healthy
4. Run `CREATE EXTENSION pg_clickhouse` so it's ready to use

### 🧱 Architecture

```
┌───────────────────────────────────┐  bridge net: pgch_net  ┌────────────────────────────────┐
│ pgch-postgres                     │ ─────────────────────► │ pgch-clickhouse                │
│   ghcr.io/clickhouse/pg_clickhouse│   binary :9000         │   clickhouse/clickhouse-server │
│   PG 18.6 + pg_clickhouse 0.11.0  │                        │   ClickHouse 26.9.7.9          │
│   + pg_cron 1.6.8                 │                        │                                │
│   exposed on host :5432           │ ◄───────────────────── │   exposed on host :8123/:9000  │
└───────────────────────────────────┘     query results      └────────────────────────────────┘
```

### 📚 Lab Details

#### 01 — Extension + Foreign Server + User Mapping ([01-extension-and-server.sql](01-extension-and-server.sql))

Step 01 does three things:
- installs `pg_clickhouse` and inspects the `clickhouse_fdw` foreign-data wrapper
- creates a `SERVER` and a `USER MAPPING`
- checks the connection: `clickhouse_server_version('ch_srv')` reports `26.9.7`, and a small `clickhouse_query()` returns a count

Key syntax:

```sql
CREATE EXTENSION pg_clickhouse;

CREATE SERVER ch_srv
    FOREIGN DATA WRAPPER clickhouse_fdw
    OPTIONS (driver 'binary', host 'clickhouse', port '9000', dbname 'default');

CREATE USER MAPPING FOR CURRENT_USER
    SERVER ch_srv
    OPTIONS (user 'default', password '');
```

The `driver` option chooses the transport:
- **`binary`** — the native protocol: port 9000, or 9440 with TLS. It supports `compression` (`lz4` by default, also `zstd` or `none`).
- **`http`** — HTTP on port 8123, or 8443 with TLS. Since 0.10 it also uses ClickHouse's Native format, so both drivers stream results block by block.

The `secure` option (`auto`, `on` or `off`) controls TLS explicitly. `auto` uses TLS for ClickHouse Cloud hosts and secure ports.

#### 02 — `IMPORT FOREIGN SCHEMA` ([02-import-foreign-schema.sql](02-import-foreign-schema.sql))

Seeds two tables inside ClickHouse — `lab.events` (100k rows) and `lab.users` (1k rows). Then it imports them into PostgreSQL with a single statement:

```sql
IMPORT FOREIGN SCHEMA lab FROM SERVER ch_srv INTO imported_lab;
```

Variants:

```sql
IMPORT FOREIGN SCHEMA lab LIMIT TO (events)   FROM SERVER ch_srv INTO imported_lab;
IMPORT FOREIGN SCHEMA lab EXCEPT   (users)    FROM SERVER ch_srv INTO imported_lab;
```

Type-mapping highlights, from the [v0.11.0 data types table](https://github.com/ClickHouse/pg_clickhouse/blob/v0.11.0/doc/pg_clickhouse.md#data-types):

| ClickHouse | PostgreSQL | Note |
|---|---|---|
| `UInt8` / `UInt16` / `UInt32` | `smallint` / `integer` / `bigint` | |
| `UInt64` | `numeric(20,0)` | Since 0.11; `lab.events.event_id` imports this way |
| `Int8` / `Int16` / `Int32` / `Int64` | `smallint` / `smallint` / `integer` / `bigint` | |
| `Int128` / `Int256` / `UInt128` / `UInt256` | `numeric(39,0)` … `numeric(78,0)` | Since 0.11 |
| `Float32` / `Float64` | `real` / `double precision` | |
| `Decimal(p,s)` | `numeric(p,s)` | |
| `Date` / `Date32` | `date` | |
| `DateTime` | `timestamptz` | |
| `DateTime64(P)` | `timestamptz(P)` | P above 6 caps at 6 |
| `String` / `FixedString(N)` | `text` | Declare `bytea` to keep raw bytes |
| `LowCardinality(T)` | same as `T` | |
| `UUID` | `uuid` | |
| `IPv4` / `IPv6` | `inet` | |
| `Bool` | `boolean` | |
| `JSON` | `jsonb` | |

Columns that are not `Nullable` in ClickHouse import as `NOT NULL`. That lets more `IN` filters push down in their cheap form.

#### 03 — Pushdown demonstrations ([03-pushdown-and-aggregates.sql](03-pushdown-and-aggregates.sql))

Every `EXPLAIN (VERBOSE)` shows the **`Remote SQL`** line, which is the exact ClickHouse query the extension produced. Check it first whenever you need to know what ClickHouse actually executed. For example, the `GROUP BY` in section 2 arrives as:

```
Remote SQL: SELECT event_type, count(*), cast(avg(amount), 'Nullable(Decimal(10,2))'), cast(sum(amount), 'Nullable(Decimal(12,2))') FROM lab.events GROUP BY event_type ORDER BY count(*) DESC NULLS FIRST
```

Demonstrated pushdowns:
- `WHERE` with multiple predicates
- `GROUP BY` with `count`/`avg`/`sum`
- `JOIN` across two foreign tables (both joins run inside ClickHouse)
- `count(DISTINCT user_id)`
- `row_number() OVER (PARTITION BY … ORDER BY …)` window function
- `date_trunc('hour', …)`, which arrives as `toStartOfHour(event_time)`

Session-level ClickHouse settings are forwarded through `pg_clickhouse.session_settings`. Its default is:

```
join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0
```

Setting it replaces the whole list. Pushdown correctness depends on `join_use_nulls` (outer joins) and `transform_null_in` (the `IN` family), so keep them when you add your own settings:

```sql
SET pg_clickhouse.session_settings =
    'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, connect_timeout 5, max_block_size 8192';
```

#### 04 — `clickhouse_query` / `clickhouse_perform` + dictionaries ([04-raw-query-and-dictionary.sql](04-raw-query-and-dictionary.sql))

Use these two to send any SQL to ClickHouse through an existing foreign server. They reuse its driver, credentials and database:

```sql
-- Rows back: declare the result columns
SELECT * FROM clickhouse_query('ch_srv', 'SELECT version()') AS t(clickhouse_version text);

-- No rows back (DDL, INSERT): CALL the procedure
CALL clickhouse_perform('ch_srv', $$CREATE TABLE lab.t (id Int32) ENGINE = MergeTree ORDER BY id$$);
```

They replace `clickhouse_raw_query(sql, connection_string)`. That function was deprecated in 0.10 and **removed in 0.11**; calling it now fails with `function clickhouse_raw_query(unknown, unknown) does not exist`. If you are upgrading an existing installation, run `ALTER EXTENSION pg_clickhouse UPDATE TO '0.11'`.

The lab uses them to:
1. Create a ClickHouse `MergeTree` table (`country_lookup`) and fill it
2. Map it back into PG via `CREATE FOREIGN TABLE`
3. Create a CH `DICTIONARY` (`country_dict`)
4. Demonstrate `dictGet()` pushdown when used in `WHERE`
5. Project dictionary attributes, which do not push down from the `SELECT` list, by running the whole query in `clickhouse_query()` with typed columns

**Security note:** `EXECUTE` on both is revoked from `PUBLIC`. Superusers can call them; grant them only to roles that legitimately need ad-hoc ClickHouse access:

```sql
GRANT EXECUTE ON FUNCTION  clickhouse_query(text, text)   TO data_engineer;
GRANT EXECUTE ON PROCEDURE clickhouse_perform(text, text) TO data_engineer;
```

The role also needs `USAGE` on the foreign server and a user mapping.

#### 05–09 — Reverse ETL with pg_cron

Steps 05–09 keep a PostgreSQL serving table up to date from ClickHouse. PostgreSQL pulls: a pg_cron job calls a function, the function reads a foreign table, and the result lands in a local table. ClickHouse needs no write access to PostgreSQL, and the transaction that replaces or updates the serving table is a PostgreSQL transaction. Run them in order; 07 and 08 each leave a paused job whose history 09 reads.

#### 05 — pg_cron + the ClickHouse source ([05-pg-cron.sql](05-pg-cron.sql), [05-seed-clickhouse.sql](05-seed-clickhouse.sql))

- **pg_cron needs a server start.** It must be in `shared_preload_libraries`; `docker-compose.yml` sets it on the postgres command line with `cron.database_name=postgres`. pg_clickhouse needs neither: PostgreSQL loads it on first use.
- **Versions come from the running builds.** `pg_get_loaded_modules()` (PostgreSQL 18) reports pg_clickhouse `0.11.0`. pg_cron 1.6.8 declares no module version, so the runner prints the package version (`postgresql-18-cron 1.6.8-1.pgdg13+2`).
- **Every run is a new session.** With `cron.use_background_workers = off` (the default), each run has its own `job_pid`. A `SET` in your own session never reaches a job.
- **The source** is `retl.item_scores`, a `ReplacingMergeTree(updated_at)` table of 10,000 items, plus a tombstone table `retl.item_scores_deleted`. `IMPORT FOREIGN SCHEMA` records `engine 'ReplacingMergeTree'` without the version column. pg_clickhouse 0.11.0 does not turn that option into `FINAL`. Deduplication comes from the session setting `final 1`.

#### 06 — `session_settings`, `log_comment`, read-only users ([06-session-settings-and-tagging.sql](06-session-settings-and-tagging.sql))

One item is written three times into a table whose merges are stopped, so three versions are visible to a plain `SELECT`:

| `pg_clickhouse.session_settings` | rows for the item |
|---|---|
| default (`join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0`) | 1 |
| `'log_comment retl_demo'` | **3** — `final 1` was replaced away, with no error or warning |
| the four defaults + `log_comment retl_demo` | 1 |

The `Remote SQL` has no `FINAL` keyword in any of the three; `final` travels as a setting. `system.query_log` shows `Settings['final'] = '1'` on the first and third queries and nothing on the second.

Read-only ClickHouse users, through their own servers and user mappings:

| ClickHouse user | Result |
|---|---|
| `readonly = 1`, default `session_settings` | `IMPORT FOREIGN SCHEMA` and every query fail: `Cannot modify 'group_by_use_nulls' setting in readonly mode` |
| `readonly = 1`, `session_settings = ''` | still fails: `Cannot modify 'output_format_native_write_json_as_string' setting in readonly mode`. pg_clickhouse sends settings of its own. |
| `readonly = 2`, defaults + `log_comment` | works; the tag reaches `system.query_log` |
| `readonly = 2`, `INSERT` with an `INSERT` grant | refused: `Cannot execute query in readonly mode` |

So a read-only user for pg_clickhouse is `readonly = 2`.

A fresh session sets `pg_clickhouse.session_settings` before anything of pg_clickhouse is loaded (the parameter does not exist yet: `pg_settings` has no row for it). The value still applies: the query returns one row and its tag `retl_set_before_load` is in `system.query_log`. The [reference](https://github.com/ClickHouse/pg_clickhouse/blob/v0.11.0/doc/pg_clickhouse.md#pg_clickhousesession_settings) says to load pg_clickhouse first. `LOAD 'pg_clickhouse'` or `session_preload_libraries` costs nothing and follows it.

#### 07 — Pattern A: full refresh + swap ([07-refresh-full-swap.sql](07-refresh-full-swap.sql))

```sql
CREATE OR REPLACE FUNCTION serving.refresh_item_scores() RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
    SET LOCAL pg_clickhouse.session_settings =
        'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, log_comment retl_full_refresh';
    CREATE TABLE serving.item_scores_new (LIKE serving.item_scores INCLUDING ALL);
    INSERT INTO serving.item_scores_new SELECT item_id, score, labels, updated_at FROM ch.item_scores;
    ANALYZE serving.item_scores_new;
    SET LOCAL lock_timeout = '3s';
    ALTER TABLE serving.item_scores     RENAME TO item_scores_old;
    ALTER TABLE serving.item_scores_new RENAME TO item_scores;
    DROP TABLE serving.item_scores_old;
END $fn$;

SELECT cron.schedule('retl-full-refresh', '5 seconds', $$SELECT serving.refresh_item_scores()$$);
```

- **Positive check.** ClickHouse gets new versions of 100 items and 5 new items. The next run swaps them in: 10,005 rows, the same as `SELECT count() … FINAL` in ClickHouse.
- **Negative check.** A reader holds `ACCESS SHARE` on the serving table for 12 s. The job's first rename waits and fails after 3 s with `canceling statement due to lock timeout`; `cron.job_run_details` records it as `failed`. One or two runs fail, depending on where the 12 s fall. A new reader that arrives while the rename waits queues behind it (2.4–2.6 s in the runs) and still sees the previous snapshot. Once the long reader commits, the next run swaps.
- **Privileges are not copied** by `LIKE … INCLUDING ALL`. `ALTER DEFAULT PRIVILEGES IN SCHEMA serving GRANT SELECT ON TABLES TO app_reader` gives each new table the grant; `has_table_privilege` stays true after every swap.
- **A view on the live table breaks every cycle.** The view follows the table it was created on, which is renamed to `item_scores_old`, so `DROP TABLE` fails and the cycle rolls back.
- **Index names** come from the first `CREATE TABLE … LIKE` (`item_scores_new_pkey`) and never collide across cycles.

pg_cron runs one instance of a job at a time; a run that comes due while the previous one is still going is queued ([pg_cron 1.6.8 README](https://github.com/citusdata/pg_cron/blob/v1.6.8/README.md)).

#### 08 — Pattern B: delta upsert ([08-refresh-delta-upsert.sql](08-refresh-delta-upsert.sql))

A watermark row, a window `updated_at > watermark − 1 minute AND updated_at <= now() − 5 s`, `INSERT … ON CONFLICT DO UPDATE … WHERE t.updated_at < excluded.updated_at`, and a `DELETE … USING` the tombstone foreign table. ClickHouse has to provide a version column that only grows per item and a tombstone for each delete.

- **Positive check.** 50 updates, 3 new items and 4 deletes in ClickHouse arrive with the first run whose window covers them: 10,004 rows, equal to ClickHouse's `FINAL` count; the watermark moves.
- **Negative check.** The tombstone table is renamed away and one item is updated. Runs fail with `Unknown table expression identifier 'retl.item_scores_deleted'`. The upsert in the same cycle rolls back too: the item is not updated and the watermark does not move. After the rename back, the next run catches up, because the window reaches one minute behind the watermark.
- The `Remote SQL` carries the window as literals: `WHERE ((updated_at > '…')) AND ((updated_at <= '…'))`. Step 09 shows that ClickHouse still read the whole table for each delta. `ORDER BY item_id` does not help a filter on `updated_at`. Only the changed rows travel.

#### 09 — `system.query_log` correlation ([09-query-log-correlation.sql](09-query-log-correlation.sql))

Everything runs from PostgreSQL. `clickhouse_query()` reads `system.query_log` over the same foreign server, and `cron.job_run_details` sits next to it:

- **Per job.** One stable `log_comment` per job makes the runs comparable: count, average duration, rows read, peak memory and exception code by tag.
- **Per run.** A join on the tag and `query_start_time_microseconds BETWEEN start_time AND end_time` puts each pg_cron run next to its ClickHouse statements. It separates the two kinds of failure. The full-refresh runs that failed on `lock_timeout` have a successful ClickHouse statement: the failure was in PostgreSQL. The failed delta runs have exception code 60 (`UNKNOWN_TABLE`) on the ClickHouse side.
- **Per statement.** The `Remote SQL` of `EXPLAIN (VERBOSE)` is the text ClickHouse logs in `query`. `EXPLAIN ANALYZE` prints `Relations`, `Remote SQL` and `FDW Time`. Nothing in it names the statement in ClickHouse; `query_id` in `system.query_log` is generated by ClickHouse. When one statement matters, give it a tag of its own and read its `query_id` from `system.query_log`. The upstream request to document this recipe is [ClickHouse/pg_clickhouse#383](https://github.com/ClickHouse/pg_clickhouse/issues/383).
- `system.query_log` is written every 7.5 s (`flush_interval_milliseconds` 7500 in this image's `config.xml`); `SYSTEM FLUSH LOGS` forces it.

### 🔌 Pushdown reference (what runs on ClickHouse)

Condensed from the [v0.11.0 reference](https://github.com/ClickHouse/pg_clickhouse/blob/v0.11.0/doc/pg_clickhouse.md#function-and-operator-reference). The exact mappings and conditions are there.

**Arithmetic / math** — `abs`, `factorial`, `mod`, `pow`/`power` (float8 only; numeric runs locally since 0.11), `round`, `sin`/`cos`/`tan`/`atan`/`atan2`, `sinh`/`cosh`/`tanh`/`asinh`, `degrees`, `radians`, `pi`. `asin`, `acos`, `atanh` and `acosh` stay local.

**Date/time** — `date_part`/`extract`, `date_trunc`, `date()`, `to_timestamp(float8)`, `to_char` (constant formats with a faithful ClickHouse equivalent), `CURRENT_DATE`, `CURRENT_TIMESTAMP`/`now`/`LOCALTIMESTAMP`, `statement_`/`transaction_`/`clock_timestamp`. Date and timestamp arithmetic with intervals also pushes down.

**String** — `btrim`/`ltrim`/`rtrim` (including the three-argument forms), `concat_ws`, `lower`, `upper`, `substring`/`substr`, `length`/`octet_length`, `reverse`, `strpos`, `md5`, `sha224`/`sha256`/`sha384`/`sha512`, `encode(bytea, 'hex'|'base64')`

**Regex** — `regexp_like`, `regexp_match`, `regexp_replace`, `regexp_split_to_array`, operators `~`, `!~`, `~*`, `!~*` (constant patterns only)

**Array** — `array_position`, `array_cat`, `array_append`, `array_prepend`, `array_remove`, `array_length`, `cardinality` (counts nested elements on ClickHouse 26.9+), `array_to_string`, `string_to_array`, `split_part`, `trim_array`, `array_fill`, `array_reverse`, `array_shuffle`, `array_sample`, `array_sort`, slice `[L:U]`, contains operators `@>`/`<@`/`&&`

**JSON** — `json_extract_path_text`, `json_extract_path`, `jsonb_extract_path_text`, `jsonb_extract_path`, operators `->`, `->>`

**`IN` family and subqueries** — `IN`, `NOT IN`, `= ANY`, `<> ALL` and the rest, with PostgreSQL's NULL semantics preserved. Scalar, `EXISTS` and `IN`/`NOT IN` subqueries in `WHERE`/`HAVING` push down on ClickHouse 25.8+.

**Aggregates** — `any_value`, `array_agg`, `avg`, `bit_and`/`bit_or`/`bit_xor`, `bool_and`/`every`, `bool_or`, `count`, `corr`, `covar_pop`, `covar_samp`, `min`, `max`, `stddev_pop`, `stddev_samp`/`stddev`, `string_agg`, `sum`, `var_pop`, `var_samp`/`variance`

**Ordered-set aggregates** — `percentile_cont` and `percentile_disc`, which map to `quantile(s)` and `quantile(s)ExactLow`

**ClickHouse-native aggregates** (provided by the extension) — `argMax`, `argMin`, `uniq`, `uniqCombined`, `uniqCombined64`, `uniqExact`, `uniqHLL12`, `uniqTheta`, `quantile`, `quantileExact`

**Window** — `row_number`, `rank`, `dense_rank`, `ntile`, `cume_dist`, `percent_rank`, `lead`, `lag`, `first_value`, `last_value`, `nth_value`, `min`/`max` (with OVER)

**ClickHouse-specific** — `dictGet`, `toUInt8`/`toUInt16`/`toUInt32`/`toUInt64`/`toUInt128`

**Other extensions** — `re2` (all functions and `@~`), `intarray` `idx`, `fuzzystrmatch` `soundex`/`levenshtein`, `pgcrypto` `digest` with a constant algorithm

### 📁 File Structure

```
pg-clickhouse-lab/
├── README.md                          # This document
├── docker-compose.yml                 # PG 18 + pg_clickhouse 0.11.0 + pg_cron 1.6.8, ClickHouse 26.9.7.9
├── postgres/Dockerfile                # the pinned pg_clickhouse image + postgresql-18-cron 1.6.8
├── 00-setup.sh                        # Pull, build, start, healthcheck, CREATE EXTENSION
├── 01-extension-and-server.sh         # Runner for extension + server + user mapping
├── 01-extension-and-server.sql        # SQL
├── 02-import-foreign-schema.sh        # Runner (seeds CH, then imports schema)
├── 02-seed-clickhouse.sql             # CH-side seed data
├── 02-import-foreign-schema.sql       # PG-side IMPORT FOREIGN SCHEMA
├── 03-pushdown-and-aggregates.sh      # Runner
├── 03-pushdown-and-aggregates.sql     # JOIN/GROUP BY/window pushdown demos
├── 04-raw-query-and-dictionary.sh     # Runner
├── 04-raw-query-and-dictionary.sql    # clickhouse_query / clickhouse_perform + DICTIONARY demo
├── 05-pg-cron.sh                      # Runner (seeds CH, then pg_cron + IMPORT FOREIGN SCHEMA)
├── 05-seed-clickhouse.sql             # CH side: retl.item_scores, tombstones, read-only users
├── 05-pg-cron.sql                     # pg_cron, versions, a new session per run
├── 06-session-settings-and-tagging.sh # Runner (+ a fresh-session check and the query_log view)
├── 06-session-settings-and-tagging.sql# session_settings defaults, log_comment, readonly 1 vs 2
├── 07-refresh-full-swap.sh            # Runner: positive check, lock_timeout negative check
├── 07-refresh-full-swap.sql           # Pattern A function and schedule
├── 08-refresh-delta-upsert.sh         # Runner: positive check, failing-cycle negative check
├── 08-refresh-delta-upsert.sql        # Pattern B function and schedule
├── 09-query-log-correlation.sh        # Runner
├── 09-query-log-correlation.sql       # cron.job_run_details next to system.query_log
├── cron-helpers.sh                    # Wait for pg_cron runs (sourced by 07 and 08)
├── psql.sh                            # `docker exec -it … psql` wrapper
├── clickhouse-client.sh               # `docker exec -it … clickhouse-client` wrapper
└── cleanup.sh                         # docker compose down -v
```

The `04-raw-query-*` file names predate 0.11. They are kept so existing links keep working.

### ⚠️ Known caveats (from the v0.11.0 docs)

- **`COPY TO` from a foreign table** is rejected by PostgreSQL itself; use `COPY (SELECT …) TO`. `COPY FROM` streams rows to ClickHouse in bulk.
- **Text is validated against the database encoding** since 0.11. Invalid bytes raise an error unless the server sets `encoding_check` to `replace`, `remove` or `truncate`.
- **Binary data belongs in `bytea`.** A `text` column drops a `FixedString`'s trailing NUL padding, where `bytea` keeps every byte.
- **Identifiers with uppercase or spaces** are double-quoted by `IMPORT FOREIGN SCHEMA`, so queries must quote them too.
- **Frame specifications on ranking window functions** are omitted during pushdown, because ClickHouse rejects them.

### 🔍 Additional resources

- [Introducing pg_clickhouse](https://clickhouse.com/blog/introducing-pg_clickhouse) — launch announcement
- [pg_clickhouse is the fastest Postgres extension on ClickBench](https://clickhouse.com/blog/pg_clickhouse-fastest-analytics-for-postgres)
- [Postgres managed by ClickHouse is now in beta](https://clickhouse.com/blog/postgres-managed-by-clickhouse-beta)
- [Reference doc (markdown)](https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/pg_clickhouse.md)
- [Tutorial doc (markdown)](https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/tutorial.md)
- [Changelog](https://github.com/ClickHouse/pg_clickhouse/blob/main/CHANGELOG.md)

### 📝 Notes

- **Verified 2026-11-05** on pg_clickhouse 0.11.0 (PostgreSQL 18.6) with pg_cron 1.6.8 (`postgresql-18-cron 1.6.8-1.pgdg13+2`) and ClickHouse 26.9.7.9, versions read from the running builds. From a clean stack, steps 00–09 ran end to end; then 05–09 ran again without cleanup. Only arm64 was run; amd64 was not. The host ports were not published during these runs (a compose override with `ports: !reset []`), because other local stacks were using them; every script reaches the containers with `docker exec`.
- Earlier: **2026-10-01**, steps 00–04 on the pg_clickhouse image without pg_cron, twice, arm64.
- Re-running any lab script is idempotent — `IF EXISTS` guards and `DROP … CASCADE` keep state consistent. On a second pass, step 02's `IMPORT FOREIGN SCHEMA lab` also picks up `country_lookup` and `country_dict`, which step 04 created in the same ClickHouse database. Step 05 recreates the ClickHouse database `retl`, so 06–09 start from the same data each time.
- Steps 07 and 08 leave their jobs paused (`cron.alter_job(…, active := false)`). `cleanup.sh` removes the containers and volumes; the locally built `pgch-postgres-cron` image stays until `docker image rm pgch-postgres-cron:18-0.11.0-1.6.8`.
- The compose stack uses a bridge network (`pgch_net`) instead of `--network host`, so it works on macOS Docker Desktop where host networking is limited

---

**Happy Learning! 🚀**

For questions or issues, see the [repository README](../../README.md).

---

## 한국어

> **관련 글**: [pg_clickhouse — PostgreSQL에서 ClickHouse 사용하기](https://clickhouse.litkhai.dev/articles/feature/pg-clickhouse-postgresql-clickhouse/)

도커만 있으면 되는 자급자족 랩입니다. 공식 **`pg_clickhouse`** PostgreSQL 익스텐션을 처음부터 끝까지 실습합니다.

pg_clickhouse 0.11.0과 pg_cron 1.6.8이 든 PostgreSQL 18, 그리고 ClickHouse 26.9.7.9를 비공개 도커 네트워크에 함께 띄웁니다. 익스텐션 설치, foreign server 등록, 스키마 임포트, 푸시다운 관찰, `clickhouse_query()` / `clickhouse_perform()`으로 ClickHouse SQL 직접 실행까지 진행합니다. 05–09단계는 방향을 뒤집습니다. PostgreSQL의 pg_cron 작업이 ClickHouse 결과를 로컬 조회용 테이블로 당겨 옵니다(리버스 ETL). 호스트에는 아무것도 설치하지 않습니다.

### 📋 `pg_clickhouse`란?

`pg_clickhouse`는 ClickHouse가 2025년 12월에 공개한 **Apache 2.0 라이선스** PostgreSQL 익스텐션입니다. PostgreSQL 클라이언트가 **SQL을 다시 작성하지 않고도** ClickHouse에 분석 쿼리를 실행하게 해 줍니다. 익스텐션이 각 쿼리를 파싱하고, 변환 가능한 부분을 **ClickHouse에 푸시다운**해 실행합니다. PostgreSQL로 돌아오는 것은 최종 결과 행뿐입니다.

- **레포지토리**: [ClickHouse/pg_clickhouse](https://github.com/ClickHouse/pg_clickhouse)
- **공식 문서**: [clickhouse.com/docs/integrations/pg_clickhouse](https://clickhouse.com/docs/integrations/pg_clickhouse)
- **PGXN**: [pgxn.org/dist/pg_clickhouse](https://pgxn.org/dist/pg_clickhouse)
- **사전 빌드 이미지**: `ghcr.io/clickhouse/pg_clickhouse:<PG 메이저>-<릴리스>`. 0.11.0은 PG 14–18용이 게시돼 있습니다(GHCR 태그 목록, 2026-10-01 조회). 이 랩은 `18-0.11.0`을 씁니다.
- **지원**: PostgreSQL 14+ (0.11에서 PG 13 지원 중단) 및 ClickHouse 23.3+
- **라이선스**: Apache-2.0
- **2026년 1월 기준** ClickBench에서 **가장 빠른** PG 분석 익스텐션이었음

### 🎯 이 랩에서 다루는 내용

| 단계 | 주제 | 핵심 |
|---|---|---|
| 01 | 익스텐션 + Foreign Server + User Mapping | `CREATE EXTENSION`, `CREATE SERVER`, `CREATE USER MAPPING`, `clickhouse_server_version`, `clickhouse_query` |
| 02 | `IMPORT FOREIGN SCHEMA` | CH 테이블 전체를 PG foreign table로 자동 생성, 타입 매핑표 |
| 03 | 푸시다운 시연 | `EXPLAIN (VERBOSE)`로 JOIN/GROUP BY/윈도우 함수 푸시다운 확인 |
| 04 | `clickhouse_query` / `clickhouse_perform` + 딕셔너리 | PG에서 CH 객체를 만든 뒤 `dictGet` 푸시다운 |
| 05 | pg_cron + 리버스 ETL 원본 | pg_cron 사전 로드, 실행마다 새 세션, `ReplacingMergeTree` 테이블의 `IMPORT FOREIGN SCHEMA` |
| 06 | `session_settings`, `log_comment`, 읽기 전용 사용자 | 기본값을 바꾸면 `final 1`이 빠짐, 작업 태깅, `readonly = 1`과 `readonly = 2` |
| 07 | 패턴 A — 전면 갱신 + 교체 | 5초마다 새로 만들고 `ANALYZE` 후 한 트랜잭션에서 rename, 오래 읽는 조회가 있으면 교체가 `lock_timeout`으로 실패 |
| 08 | 패턴 B — 델타 upsert | 워터마크 구간, `ON CONFLICT`, 텀스톤, 실패한 주기는 테이블과 워터마크를 그대로 둠 |
| 09 | `system.query_log` 대조 | pg_cron 실행 한 줄마다 그 실행의 ClickHouse 문장, `EXPLAIN ANALYZE`에는 query id가 없음 |

### 🚀 빠른 시작

```bash
cd extensions/pg-clickhouse-lab
./00-setup.sh

# 랩 진행
./01-extension-and-server.sh
./02-import-foreign-schema.sh
./03-pushdown-and-aggregates.sh
./04-raw-query-and-dictionary.sh

# pg_cron 리버스 ETL (순서대로, 07–09는 합쳐 1분쯤)
./05-pg-cron.sh
./06-session-settings-and-tagging.sh
./07-refresh-full-swap.sh
./08-refresh-delta-upsert.sh
./09-query-log-correlation.sh

# 인터랙티브 셸
./psql.sh                    # pgch-postgres에 psql 접속
./clickhouse-client.sh       # pgch-clickhouse에 clickhouse-client 접속

# 전부 정리
./cleanup.sh
```

`00-setup.sh`는 다음을 수행합니다:
1. `clickhouse/clickhouse-server:26.9.7.9`를 pull하고, [postgres/Dockerfile](postgres/Dockerfile)로 `pgch-postgres-cron`을 빌드합니다. `ghcr.io/clickhouse/pg_clickhouse:18-0.11.0`에 PGDG 패키지 `postgresql-18-cron` 1.6.8을 더한 이미지입니다. ClickHouse 이미지와 베이스 이미지는 멀티 아키텍처 digest로, 패키지는 버전으로 고정돼 있고, 그 이유는 [STATUS.md](../../STATUS.md)에 있습니다. 빌드에는 PGDG apt 저장소에 닿는 네트워크가 필요합니다.
2. 비공개 브리지 네트워크 (`pgch_net`)에서 두 컨테이너 기동. postgres 명령줄에 `shared_preload_libraries=pg_cron`
3. 둘 다 healthy 상태가 될 때까지 대기
4. `CREATE EXTENSION pg_clickhouse` 실행해 사용 준비 완료

### 🧱 아키텍처

```
┌───────────────────────────────────┐  bridge net: pgch_net  ┌────────────────────────────────┐
│ pgch-postgres                     │ ─────────────────────► │ pgch-clickhouse                │
│   ghcr.io/clickhouse/pg_clickhouse│   binary :9000         │   clickhouse/clickhouse-server │
│   PG 18.6 + pg_clickhouse 0.11.0  │                        │   ClickHouse 26.9.7.9          │
│   + pg_cron 1.6.8                 │                        │                                │
│   exposed on host :5432           │ ◄───────────────────── │   exposed on host :8123/:9000  │
└───────────────────────────────────┘     query results      └────────────────────────────────┘
```

### 📚 랩 상세

#### 01 — 익스텐션 + Foreign Server + User Mapping ([01-extension-and-server.sql](01-extension-and-server.sql))

01단계는 세 가지를 합니다.
- `pg_clickhouse`를 설치하고 `clickhouse_fdw` foreign-data wrapper를 확인합니다.
- `SERVER`와 `USER MAPPING`을 생성합니다.
- 연결을 확인합니다. `clickhouse_server_version('ch_srv')`가 `26.9.7`을 돌려주고, 작은 `clickhouse_query()`가 건수를 돌려줍니다.

주요 구문:

```sql
CREATE EXTENSION pg_clickhouse;

CREATE SERVER ch_srv
    FOREIGN DATA WRAPPER clickhouse_fdw
    OPTIONS (driver 'binary', host 'clickhouse', port '9000', dbname 'default');

CREATE USER MAPPING FOR CURRENT_USER
    SERVER ch_srv
    OPTIONS (user 'default', password '');
```

`driver` 옵션은 전송 방식을 선택합니다:
- **`binary`** — 네이티브 프로토콜입니다. 9000번 포트, TLS면 9440번을 씁니다. `compression`을 지원합니다(기본 `lz4`, 그 밖에 `zstd`, `none`).
- **`http`** — HTTP 8123번 포트, TLS면 8443번을 씁니다. 0.10부터 이쪽도 ClickHouse Native 포맷을 쓰므로, 두 드라이버 모두 결과를 블록 단위로 스트리밍합니다.

`secure` 옵션(`auto`, `on`, `off`)으로 TLS를 명시적으로 정할 수 있습니다. `auto`는 ClickHouse Cloud 호스트와 보안 포트에 TLS를 씁니다.

#### 02 — `IMPORT FOREIGN SCHEMA` ([02-import-foreign-schema.sql](02-import-foreign-schema.sql))

ClickHouse에 두 테이블을 시드합니다. `lab.events`는 10만 행, `lab.users`는 1천 행입니다. 그런 다음 한 줄로 PostgreSQL에 임포트합니다:

```sql
IMPORT FOREIGN SCHEMA lab FROM SERVER ch_srv INTO imported_lab;
```

변형 구문:

```sql
IMPORT FOREIGN SCHEMA lab LIMIT TO (events)   FROM SERVER ch_srv INTO imported_lab;
IMPORT FOREIGN SCHEMA lab EXCEPT   (users)    FROM SERVER ch_srv INTO imported_lab;
```

타입 매핑 요약 ([v0.11.0 데이터 타입 표](https://github.com/ClickHouse/pg_clickhouse/blob/v0.11.0/doc/pg_clickhouse.md#data-types) 기준):

| ClickHouse | PostgreSQL | 비고 |
|---|---|---|
| `UInt8` / `UInt16` / `UInt32` | `smallint` / `integer` / `bigint` | |
| `UInt64` | `numeric(20,0)` | 0.11부터. `lab.events.event_id`가 이렇게 임포트됨 |
| `Int8` / `Int16` / `Int32` / `Int64` | `smallint` / `smallint` / `integer` / `bigint` | |
| `Int128` / `Int256` / `UInt128` / `UInt256` | `numeric(39,0)` … `numeric(78,0)` | 0.11부터 |
| `Float32` / `Float64` | `real` / `double precision` | |
| `Decimal(p,s)` | `numeric(p,s)` | |
| `Date` / `Date32` | `date` | |
| `DateTime` | `timestamptz` | |
| `DateTime64(P)` | `timestamptz(P)` | P는 최대 6 |
| `String` / `FixedString(N)` | `text` | 원본 바이트가 필요하면 `bytea`로 선언 |
| `LowCardinality(T)` | `T`와 동일 | |
| `UUID` | `uuid` | |
| `IPv4` / `IPv6` | `inet` | |
| `Bool` | `boolean` | |
| `JSON` | `jsonb` | |

ClickHouse에서 `Nullable`이 아닌 컬럼은 `NOT NULL`로 임포트됩니다. 그래서 `IN` 필터가 더 싼 형태로 푸시다운될 수 있습니다.

#### 03 — 푸시다운 시연 ([03-pushdown-and-aggregates.sql](03-pushdown-and-aggregates.sql))

모든 `EXPLAIN (VERBOSE)`는 **`Remote SQL`** 줄을 보여 줍니다. 익스텐션이 실제로 ClickHouse에 보낸 쿼리입니다. ClickHouse가 무엇을 실행했는지 알고 싶을 때 가장 먼저 볼 출력입니다. 예를 들어 2절의 `GROUP BY`는 이렇게 도착합니다:

```
Remote SQL: SELECT event_type, count(*), cast(avg(amount), 'Nullable(Decimal(10,2))'), cast(sum(amount), 'Nullable(Decimal(12,2))') FROM lab.events GROUP BY event_type ORDER BY count(*) DESC NULLS FIRST
```

시연되는 푸시다운:
- 여러 조건의 `WHERE`
- `GROUP BY` + `count`/`avg`/`sum`
- 두 foreign table간 `JOIN` (조인이 ClickHouse 내부에서 실행됨)
- `count(DISTINCT user_id)`
- `row_number() OVER (PARTITION BY … ORDER BY …)` 윈도우 함수
- `date_trunc('hour', …)` — `toStartOfHour(event_time)`으로 도착

세션 단위 ClickHouse 설정은 `pg_clickhouse.session_settings`로 전달됩니다. 기본값은 다음과 같습니다:

```
join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0
```

값을 설정하면 목록 전체가 바뀝니다. 푸시다운의 정확성은 `join_use_nulls`(외부 조인)와 `transform_null_in`(`IN` 계열)에 달려 있으니, 설정을 덧붙일 때도 이 둘은 남겨 두세요:

```sql
SET pg_clickhouse.session_settings =
    'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, connect_timeout 5, max_block_size 8192';
```

#### 04 — `clickhouse_query` / `clickhouse_perform` + 딕셔너리 ([04-raw-query-and-dictionary.sql](04-raw-query-and-dictionary.sql))

이미 만든 foreign server를 통해 ClickHouse에 임의의 SQL을 보낼 때 이 둘을 씁니다. 서버의 드라이버, 자격 증명, 데이터베이스를 그대로 씁니다:

```sql
-- 행을 돌려받을 때: 결과 컬럼을 선언
SELECT * FROM clickhouse_query('ch_srv', 'SELECT version()') AS t(clickhouse_version text);

-- 돌려받을 행이 없을 때 (DDL, INSERT): 프로시저를 CALL
CALL clickhouse_perform('ch_srv', $$CREATE TABLE lab.t (id Int32) ENGINE = MergeTree ORDER BY id$$);
```

둘은 `clickhouse_raw_query(sql, connection_string)`을 대체합니다. 그 함수는 0.10에서 deprecated됐고 **0.11에서 삭제됐습니다**. 지금 호출하면 `function clickhouse_raw_query(unknown, unknown) does not exist`로 실패합니다. 기존 설치를 올리는 경우 `ALTER EXTENSION pg_clickhouse UPDATE TO '0.11'`을 실행하세요.

랩에서는 이를 사용해:
1. ClickHouse `MergeTree` 테이블 (`country_lookup`) 생성과 적재
2. `CREATE FOREIGN TABLE`로 PG에 매핑
3. CH `DICTIONARY` (`country_dict`) 생성
4. `WHERE`에서 `dictGet()` 푸시다운 시연
5. SELECT 리스트에서는 딕셔너리 속성이 푸시다운되지 않습니다. 그래서 쿼리 전체를 `clickhouse_query()`로 실행하고 컬럼 타입을 선언해 돌려받습니다.

**보안 노트:** 두 함수 모두 `PUBLIC`의 `EXECUTE` 권한이 회수돼 있습니다. 슈퍼유저는 호출할 수 있습니다. 정당하게 ad-hoc ClickHouse 접근이 필요한 역할에만 부여하세요:

```sql
GRANT EXECUTE ON FUNCTION  clickhouse_query(text, text)   TO data_engineer;
GRANT EXECUTE ON PROCEDURE clickhouse_perform(text, text) TO data_engineer;
```

그 역할에는 foreign server에 대한 `USAGE`와 user mapping도 필요합니다.

#### 05–09 — pg_cron으로 리버스 ETL

05–09단계는 PostgreSQL 조회용 테이블을 ClickHouse 기준으로 계속 갱신합니다. 당기는 쪽은 PostgreSQL입니다. pg_cron 작업이 함수를 부르고, 함수가 foreign table을 읽어 로컬 테이블에 넣습니다. ClickHouse에 PostgreSQL 쓰기 권한이 필요 없고, 조회용 테이블을 바꾸거나 고치는 트랜잭션은 PostgreSQL 트랜잭션입니다. 순서대로 실행하세요. 07과 08은 일시 정지한 작업을 남기고, 09가 그 실행 이력을 읽습니다.

#### 05 — pg_cron + ClickHouse 원본 ([05-pg-cron.sql](05-pg-cron.sql), [05-seed-clickhouse.sql](05-seed-clickhouse.sql))

- **pg_cron은 서버 기동이 필요합니다.** `shared_preload_libraries`에 있어야 해서, `docker-compose.yml`이 postgres 명령줄에 `cron.database_name=postgres`와 함께 넣습니다. pg_clickhouse는 둘 다 필요 없습니다. 처음 쓸 때 PostgreSQL이 읽어 들입니다.
- **버전은 실행 중인 빌드에서 읽습니다.** `pg_get_loaded_modules()`(PostgreSQL 18)가 pg_clickhouse `0.11.0`을 보여 줍니다. pg_cron 1.6.8은 모듈 버전을 선언하지 않아서, 러너가 패키지 버전(`postgresql-18-cron 1.6.8-1.pgdg13+2`)을 출력합니다.
- **실행마다 새 세션입니다.** `cron.use_background_workers = off`(기본값)에서는 실행마다 `job_pid`가 다릅니다. 내 세션에서 한 `SET`은 작업에 닿지 않습니다.
- **원본**은 항목 1만 개의 `ReplacingMergeTree(updated_at)` 테이블 `retl.item_scores`와 텀스톤 테이블 `retl.item_scores_deleted`입니다. `IMPORT FOREIGN SCHEMA`는 버전 컬럼 없이 `engine 'ReplacingMergeTree'`만 기록합니다. pg_clickhouse 0.11.0은 이 옵션을 `FINAL`로 바꾸지 않습니다. 중복 제거는 세션 설정 `final 1`이 합니다.

#### 06 — `session_settings`, `log_comment`, 읽기 전용 사용자 ([06-session-settings-and-tagging.sql](06-session-settings-and-tagging.sql))

머지를 멈춘 테이블에 항목 하나를 세 번 써서, 평범한 `SELECT`에 세 버전이 보이게 합니다:

| `pg_clickhouse.session_settings` | 그 항목의 행 수 |
|---|---|
| 기본값 (`join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0`) | 1 |
| `'log_comment retl_demo'` | **3** — `final 1`이 교체돼 사라졌고, 오류도 경고도 없음 |
| 기본값 네 개 + `log_comment retl_demo` | 1 |

세 경우 모두 `Remote SQL`에 `FINAL` 키워드는 없습니다. `final`은 설정으로 넘어갑니다. `system.query_log`에서 첫째와 셋째 쿼리는 `Settings['final'] = '1'`, 둘째는 값이 없습니다.

읽기 전용 ClickHouse 사용자(각자 서버와 user mapping을 따로 둠):

| ClickHouse 사용자 | 결과 |
|---|---|
| `readonly = 1`, `session_settings` 기본값 | `IMPORT FOREIGN SCHEMA`와 모든 쿼리 실패: `Cannot modify 'group_by_use_nulls' setting in readonly mode` |
| `readonly = 1`, `session_settings = ''` | 그래도 실패: `Cannot modify 'output_format_native_write_json_as_string' setting in readonly mode`. pg_clickhouse가 자기 설정을 따로 보냅니다. |
| `readonly = 2`, 기본값 + `log_comment` | 동작. 태그가 `system.query_log`에 남음 |
| `readonly = 2`, `INSERT` 권한을 준 상태에서 `INSERT` | 거부: `Cannot execute query in readonly mode` |

그래서 pg_clickhouse용 읽기 전용 사용자는 `readonly = 2`입니다.

새 세션에서 pg_clickhouse를 아직 아무것도 읽지 않은 상태로(파라미터가 아직 없어 `pg_settings`에 행이 없음) `pg_clickhouse.session_settings`를 먼저 `SET`합니다. 그래도 값이 적용됩니다. 쿼리는 1행을 돌려주고 태그 `retl_set_before_load`가 `system.query_log`에 있습니다. [레퍼런스](https://github.com/ClickHouse/pg_clickhouse/blob/v0.11.0/doc/pg_clickhouse.md#pg_clickhousesession_settings)는 pg_clickhouse를 먼저 로드하라고 합니다. `LOAD 'pg_clickhouse'`나 `session_preload_libraries`는 비용이 없으니 레퍼런스를 따르세요.

#### 07 — 패턴 A: 전면 갱신 + 교체 ([07-refresh-full-swap.sql](07-refresh-full-swap.sql))

```sql
CREATE OR REPLACE FUNCTION serving.refresh_item_scores() RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
    SET LOCAL pg_clickhouse.session_settings =
        'join_use_nulls 1, group_by_use_nulls 1, final 1, transform_null_in 0, log_comment retl_full_refresh';
    CREATE TABLE serving.item_scores_new (LIKE serving.item_scores INCLUDING ALL);
    INSERT INTO serving.item_scores_new SELECT item_id, score, labels, updated_at FROM ch.item_scores;
    ANALYZE serving.item_scores_new;
    SET LOCAL lock_timeout = '3s';
    ALTER TABLE serving.item_scores     RENAME TO item_scores_old;
    ALTER TABLE serving.item_scores_new RENAME TO item_scores;
    DROP TABLE serving.item_scores_old;
END $fn$;

SELECT cron.schedule('retl-full-refresh', '5 seconds', $$SELECT serving.refresh_item_scores()$$);
```

- **성공 확인.** ClickHouse에 항목 100개의 새 버전과 새 항목 5개를 넣습니다. 다음 실행이 교체해 넣습니다. 10,005행으로, ClickHouse의 `SELECT count() … FINAL`과 같습니다.
- **실패 확인.** 한 조회가 조회용 테이블에 `ACCESS SHARE`를 12초 잡고 있습니다. 작업의 첫 rename이 기다리다 3초 뒤 `canceling statement due to lock timeout`으로 실패하고, `cron.job_run_details`에 `failed`로 남습니다. 12초가 어디에 걸리느냐에 따라 한두 번 실패합니다. rename이 기다리는 동안 들어온 새 조회는 그 뒤에 줄을 서고(실행에서 2.4–2.6초), 그래도 이전 스냅샷을 봅니다. 오래 읽던 조회가 커밋하면 다음 실행이 교체합니다.
- **권한은 복사되지 않습니다.** `LIKE … INCLUDING ALL`은 권한을 가져오지 않습니다. `ALTER DEFAULT PRIVILEGES IN SCHEMA serving GRANT SELECT ON TABLES TO app_reader`가 새 테이블마다 권한을 줘서, 교체 뒤에도 `has_table_privilege`가 참입니다.
- **조회용 테이블 위의 뷰는 매 주기를 깨뜨립니다.** 뷰는 만들 때의 테이블을 따라가는데, 그 테이블이 `item_scores_old`로 바뀌므로 `DROP TABLE`이 실패하고 주기 전체가 롤백됩니다.
- **인덱스 이름**은 처음 `CREATE TABLE … LIKE`에서 정해지고(`item_scores_new_pkey`), 주기가 돌아도 충돌하지 않습니다.

pg_cron은 한 작업을 한 번에 하나만 실행합니다. 앞 실행이 끝나기 전에 다음 차례가 오면 줄을 세웠다가 실행합니다([pg_cron 1.6.8 README](https://github.com/citusdata/pg_cron/blob/v1.6.8/README.md)).

#### 08 — 패턴 B: 델타 upsert ([08-refresh-delta-upsert.sql](08-refresh-delta-upsert.sql))

워터마크 행 하나, 구간 `updated_at > 워터마크 − 1분 AND updated_at <= now() − 5초`, `INSERT … ON CONFLICT DO UPDATE … WHERE t.updated_at < excluded.updated_at`, 텀스톤 foreign table을 쓰는 `DELETE … USING`으로 이뤄집니다. ClickHouse 쪽에는 항목마다 커지기만 하는 버전 컬럼과, 삭제마다 텀스톤이 있어야 합니다.

- **성공 확인.** ClickHouse의 갱신 50건, 새 항목 3개, 삭제 4건이 그 구간을 덮는 첫 실행에서 들어옵니다. 10,004행으로 ClickHouse의 `FINAL` 건수와 같고, 워터마크가 움직입니다.
- **실패 확인.** 텀스톤 테이블 이름을 바꿔 치우고 항목 하나를 갱신합니다. 실행이 `Unknown table expression identifier 'retl.item_scores_deleted'`로 실패합니다. 같은 주기의 upsert도 함께 롤백돼, 그 항목은 갱신되지 않고 워터마크도 그대로입니다. 이름을 되돌리면 구간이 워터마크보다 1분 앞에서 시작하므로 다음 실행이 따라잡습니다.
- `Remote SQL`은 구간을 리터럴로 싣습니다: `WHERE ((updated_at > '…')) AND ((updated_at <= '…'))`. 09단계에서 보듯 ClickHouse는 델타마다 테이블 전체를 읽었습니다. `ORDER BY item_id`는 `updated_at` 필터를 돕지 못합니다. 옮겨지는 것은 바뀐 행뿐입니다.

#### 09 — `system.query_log` 대조 ([09-query-log-correlation.sql](09-query-log-correlation.sql))

모두 PostgreSQL에서 합니다. `clickhouse_query()`가 같은 foreign server로 `system.query_log`를 읽고, `cron.job_run_details`와 나란히 놓습니다:

- **작업 단위.** 작업마다 고정된 `log_comment` 하나면 실행끼리 비교할 수 있습니다. 태그별 문장 수, 평균 시간, 읽은 행, 최대 메모리, 예외 코드.
- **실행 단위.** 태그와 `query_start_time_microseconds BETWEEN start_time AND end_time`으로 조인하면, pg_cron 실행 한 줄마다 그 실행의 ClickHouse 문장이 붙습니다. 두 종류의 실패가 갈립니다. `lock_timeout`으로 실패한 전면 갱신 실행의 ClickHouse 문장은 성공했습니다. 실패는 PostgreSQL 쪽입니다. 실패한 델타 실행에는 ClickHouse 쪽 예외 코드 60(`UNKNOWN_TABLE`)이 있습니다.
- **문장 단위.** `EXPLAIN (VERBOSE)`의 `Remote SQL`이 ClickHouse가 `query`에 남기는 문장입니다. `EXPLAIN ANALYZE`는 `Relations`, `Remote SQL`, `FDW Time`을 보여 줄 뿐, ClickHouse에서 그 문장을 가리키는 값은 없습니다. `system.query_log`의 `query_id`는 ClickHouse가 만든 것입니다. 문장 하나가 중요하면 그 문장에만 태그를 따로 붙이고 `system.query_log`에서 `query_id`를 읽습니다. 이 방법을 문서에 넣자는 upstream 요청은 [ClickHouse/pg_clickhouse#383](https://github.com/ClickHouse/pg_clickhouse/issues/383)입니다.
- `system.query_log`는 7.5초마다 기록됩니다(이 이미지 `config.xml`의 `flush_interval_milliseconds` 7500). `SYSTEM FLUSH LOGS`로 바로 쓰게 할 수 있습니다.

### 🔌 푸시다운 레퍼런스 (ClickHouse에서 실행되는 항목)

[v0.11.0 레퍼런스](https://github.com/ClickHouse/pg_clickhouse/blob/v0.11.0/doc/pg_clickhouse.md#function-and-operator-reference)를 줄인 것입니다. 정확한 매핑과 조건은 원문에 있습니다.

**산술/수학** — `abs`, `factorial`, `mod`, `pow`/`power` (float8만. numeric은 0.11부터 로컬 실행), `round`, `sin`/`cos`/`tan`/`atan`/`atan2`, `sinh`/`cosh`/`tanh`/`asinh`, `degrees`, `radians`, `pi`. `asin`, `acos`, `atanh`, `acosh`는 로컬에 남습니다.

**날짜/시간** — `date_part`/`extract`, `date_trunc`, `date()`, `to_timestamp(float8)`, `to_char` (ClickHouse에 충실한 대응이 있는 상수 포맷), `CURRENT_DATE`, `CURRENT_TIMESTAMP`/`now`/`LOCALTIMESTAMP`, `statement_`/`transaction_`/`clock_timestamp`. 날짜·타임스탬프와 interval의 연산도 푸시다운됩니다.

**문자열** — `btrim`/`ltrim`/`rtrim` (3인자 형태 포함), `concat_ws`, `lower`, `upper`, `substring`/`substr`, `length`/`octet_length`, `reverse`, `strpos`, `md5`, `sha224`/`sha256`/`sha384`/`sha512`, `encode(bytea, 'hex'|'base64')`

**정규식** — `regexp_like`, `regexp_match`, `regexp_replace`, `regexp_split_to_array`, 연산자 `~`, `!~`, `~*`, `!~*` (상수 패턴만)

**배열** — `array_position`, `array_cat`, `array_append`, `array_prepend`, `array_remove`, `array_length`, `cardinality` (ClickHouse 26.9+에서는 중첩 원소까지 셈), `array_to_string`, `string_to_array`, `split_part`, `trim_array`, `array_fill`, `array_reverse`, `array_shuffle`, `array_sample`, `array_sort`, 슬라이스 `[L:U]`, 포함 연산자 `@>`/`<@`/`&&`

**JSON** — `json_extract_path_text`, `json_extract_path`, `jsonb_extract_path_text`, `jsonb_extract_path`, 연산자 `->`, `->>`

**`IN` 계열과 서브쿼리** — `IN`, `NOT IN`, `= ANY`, `<> ALL` 등. PostgreSQL의 NULL 의미를 보존합니다. `WHERE`/`HAVING`의 스칼라·`EXISTS`·`IN`/`NOT IN` 서브쿼리는 ClickHouse 25.8+에서 푸시다운됩니다.

**집계** — `any_value`, `array_agg`, `avg`, `bit_and`/`bit_or`/`bit_xor`, `bool_and`/`every`, `bool_or`, `count`, `corr`, `covar_pop`, `covar_samp`, `min`, `max`, `stddev_pop`, `stddev_samp`/`stddev`, `string_agg`, `sum`, `var_pop`, `var_samp`/`variance`

**순서 집합 집계** — `percentile_cont`, `percentile_disc`. 각각 `quantile(s)`, `quantile(s)ExactLow`로 매핑

**ClickHouse 네이티브 집계** (익스텐션 제공) — `argMax`, `argMin`, `uniq`, `uniqCombined`, `uniqCombined64`, `uniqExact`, `uniqHLL12`, `uniqTheta`, `quantile`, `quantileExact`

**윈도우** — `row_number`, `rank`, `dense_rank`, `ntile`, `cume_dist`, `percent_rank`, `lead`, `lag`, `first_value`, `last_value`, `nth_value`, `min`/`max` (OVER 절과 함께)

**ClickHouse 전용** — `dictGet`, `toUInt8`/`toUInt16`/`toUInt32`/`toUInt64`/`toUInt128`

**다른 익스텐션** — `re2` (모든 함수와 `@~`), `intarray` `idx`, `fuzzystrmatch` `soundex`/`levenshtein`, 상수 알고리즘의 `pgcrypto` `digest`

### 📁 파일 구조

```
pg-clickhouse-lab/
├── README.md                          # 이 문서
├── docker-compose.yml                 # PG 18 + pg_clickhouse 0.11.0 + pg_cron 1.6.8, ClickHouse 26.9.7.9
├── postgres/Dockerfile                # 고정한 pg_clickhouse 이미지 + postgresql-18-cron 1.6.8
├── 00-setup.sh                        # 이미지 pull·빌드, 기동, 헬스체크, CREATE EXTENSION
├── 01-extension-and-server.sh         # 익스텐션 + 서버 + 매핑 러너
├── 01-extension-and-server.sql        # SQL
├── 02-import-foreign-schema.sh        # 러너 (CH 시드 후 IMPORT)
├── 02-seed-clickhouse.sql             # CH 쪽 시드 데이터
├── 02-import-foreign-schema.sql       # PG 쪽 IMPORT FOREIGN SCHEMA
├── 03-pushdown-and-aggregates.sh      # 러너
├── 03-pushdown-and-aggregates.sql     # JOIN/GROUP BY/윈도우 푸시다운 시연
├── 04-raw-query-and-dictionary.sh     # 러너
├── 04-raw-query-and-dictionary.sql    # clickhouse_query / clickhouse_perform + DICTIONARY 시연
├── 05-pg-cron.sh                      # 러너 (CH 시드 후 pg_cron + IMPORT FOREIGN SCHEMA)
├── 05-seed-clickhouse.sql             # CH 쪽: retl.item_scores, 텀스톤, 읽기 전용 사용자
├── 05-pg-cron.sql                     # pg_cron, 버전, 실행마다 새 세션
├── 06-session-settings-and-tagging.sh # 러너 (+ 새 세션 확인과 query_log 조회)
├── 06-session-settings-and-tagging.sql# session_settings 기본값, log_comment, readonly 1과 2
├── 07-refresh-full-swap.sh            # 러너: 성공 확인, lock_timeout 실패 확인
├── 07-refresh-full-swap.sql           # 패턴 A 함수와 스케줄
├── 08-refresh-delta-upsert.sh         # 러너: 성공 확인, 실패하는 주기 확인
├── 08-refresh-delta-upsert.sql        # 패턴 B 함수와 스케줄
├── 09-query-log-correlation.sh        # 러너
├── 09-query-log-correlation.sql       # cron.job_run_details와 system.query_log 나란히
├── cron-helpers.sh                    # pg_cron 실행 대기 (07, 08이 source)
├── psql.sh                            # `docker exec -it … psql` 래퍼
├── clickhouse-client.sh               # `docker exec -it … clickhouse-client` 래퍼
└── cleanup.sh                         # docker compose down -v
```

`04-raw-query-*` 파일 이름은 0.11 이전부터 쓰던 것입니다. 기존 링크가 깨지지 않도록 그대로 둡니다.

### ⚠️ 알려진 제약 (v0.11.0 문서 기준)

- **foreign table에서 `COPY TO`**는 PostgreSQL 자체가 거부합니다. `COPY (SELECT …) TO`를 쓰세요. `COPY FROM`은 행을 ClickHouse로 일괄 스트리밍합니다.
- **0.11부터 텍스트를 데이터베이스 인코딩으로 검증합니다.** 잘못된 바이트는 오류가 됩니다. 서버에 `encoding_check`를 `replace`, `remove`, `truncate` 중 하나로 설정하면 오류 대신 그 방식으로 처리합니다.
- **바이너리 데이터는 `bytea`에.** `text` 컬럼은 `FixedString` 끝의 NUL 패딩을 버리고, `bytea`는 모든 바이트를 유지합니다.
- **대문자나 공백이 든 식별자**는 `IMPORT FOREIGN SCHEMA`가 큰따옴표로 감싸므로, 쿼리에서도 따옴표가 필요합니다.
- **랭킹 윈도우 함수의 프레임 명세**는 ClickHouse가 거부하기 때문에 푸시다운 시 빠집니다.

### 🔍 추가 자료

- [Introducing pg_clickhouse](https://clickhouse.com/blog/introducing-pg_clickhouse) — 출시 공지
- [pg_clickhouse is the fastest Postgres extension on ClickBench](https://clickhouse.com/blog/pg_clickhouse-fastest-analytics-for-postgres)
- [Postgres managed by ClickHouse is now in beta](https://clickhouse.com/blog/postgres-managed-by-clickhouse-beta)
- [Reference doc (markdown)](https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/pg_clickhouse.md)
- [Tutorial doc (markdown)](https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/tutorial.md)
- [Changelog](https://github.com/ClickHouse/pg_clickhouse/blob/main/CHANGELOG.md)

### 📝 참고사항

- **2026-11-05 검증** — pg_clickhouse 0.11.0 (PostgreSQL 18.6) + pg_cron 1.6.8 (`postgresql-18-cron 1.6.8-1.pgdg13+2`) + ClickHouse 26.9.7.9. 버전은 실행 중인 빌드에서 읽었습니다. 깨끗한 스택에서 00–09단계를 end-to-end로 실행하고, 정리 없이 05–09단계를 한 번 더 돌렸습니다. arm64에서만 실행했고 amd64는 실행하지 않았습니다. 다른 로컬 스택이 호스트 포트를 쓰고 있어서 이번 실행에서는 포트를 열지 않았습니다(`ports: !reset []` compose override). 모든 스크립트는 `docker exec`로 컨테이너에 접속합니다.
- 이전: **2026-10-01**, pg_cron 없는 pg_clickhouse 이미지에서 00–04단계를 두 번, arm64.
- 모든 랩 스크립트는 멱등성 보장 — `IF EXISTS`와 `DROP … CASCADE`로 상태 일관성 유지. 두 번째 실행에서는 02단계의 `IMPORT FOREIGN SCHEMA lab`이 04단계가 같은 ClickHouse 데이터베이스에 만든 `country_lookup`과 `country_dict`도 함께 가져옵니다. 05단계가 ClickHouse 데이터베이스 `retl`을 새로 만들어서, 06–09단계는 매번 같은 데이터에서 시작합니다.
- 07과 08단계는 작업을 일시 정지(`cron.alter_job(…, active := false)`)한 채로 남깁니다. `cleanup.sh`는 컨테이너와 볼륨을 지우고, 로컬에서 빌드한 `pgch-postgres-cron` 이미지는 `docker image rm pgch-postgres-cron:18-0.11.0-1.6.8`로 지웁니다.
- 컴포즈 스택은 `--network host` 대신 브리지 네트워크 (`pgch_net`)를 사용해 macOS Docker Desktop에서도 동작

---

**Happy Learning! 🚀**

질문이나 이슈는 [저장소 README](../../README.md)를 참조하세요.

## License

[MIT](../../LICENSE) — same as the rest of the repository.

## 라이선스

[MIT](../../LICENSE) — 저장소 전체와 동일합니다.
