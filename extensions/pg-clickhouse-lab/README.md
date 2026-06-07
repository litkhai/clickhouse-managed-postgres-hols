# pg_clickhouse Lab — Query ClickHouse from PostgreSQL

[English](#english) | [한국어](#한국어)

---

## English

A self-contained, Docker-only lab that demonstrates the official **`pg_clickhouse`** PostgreSQL extension end-to-end. PostgreSQL 18 (with the pre-built extension) is paired with ClickHouse 26.5 on a private Docker network, so you can install the extension, register a foreign server, import schemas, observe pushdown, and call the raw-query escape hatch — all without touching your host.

### 📋 What is `pg_clickhouse`?

`pg_clickhouse` is an Apache 2.0-licensed PostgreSQL extension published by ClickHouse (December 2025). It lets PostgreSQL clients run analytic queries against ClickHouse **without rewriting any SQL** — the extension parses each query, translates the parts it can, and **pushes them down** to ClickHouse for execution. Only the final result rows come back to PostgreSQL.

- **Repository**: [ClickHouse/pg_clickhouse](https://github.com/ClickHouse/pg_clickhouse)
- **Docs**: [clickhouse.com/docs/integrations/pg_clickhouse](https://clickhouse.com/docs/integrations/pg_clickhouse)
- **PGXN**: [pgxn.org/dist/pg_clickhouse](https://pgxn.org/dist/pg_clickhouse)
- **Pre-built image**: `ghcr.io/clickhouse/pg_clickhouse:18` (also `:17`, `:16`, `:15`, `:14`, `:13`)
- **Supports**: PostgreSQL 13+ and ClickHouse v23+
- **License**: Apache-2.0
- **As of Jan 2026** it is the **fastest** PG analytics extension on ClickBench

### 🎯 What this lab covers

| Step | Topic | Highlights |
|---|---|---|
| 01 | Extension + Foreign Server + User Mapping | `CREATE EXTENSION`, `CREATE SERVER`, `CREATE USER MAPPING`, `clickhouse_raw_query` |
| 02 | `IMPORT FOREIGN SCHEMA` | Auto-create PG foreign tables for every CH table, type mapping table |
| 03 | Pushdown demonstration | `EXPLAIN (VERBOSE)` showing JOIN/GROUP BY/window-function pushdown to CH |
| 04 | Raw-query escape hatch + dictionaries | Create CH dictionaries and `dictGet` pushdown from PG |

### 🚀 Quick Start

```bash
cd local/pg-clickhouse-lab
./00-setup.sh

# Walk through the lab
./01-extension-and-server.sh
./02-import-foreign-schema.sh
./03-pushdown-and-aggregates.sh
./04-raw-query-and-dictionary.sh

# Interactive shells
./psql.sh                    # psql against pgch-postgres
./clickhouse-client.sh       # clickhouse-client against pgch-clickhouse

# Tear it all down
./cleanup.sh
```

The setup script will:
1. Pull `ghcr.io/clickhouse/pg_clickhouse:18` and `clickhouse/clickhouse-server:26.5`
2. Start them on a private bridge network (`pgch_net`)
3. Wait for both to be healthy
4. Run `CREATE EXTENSION pg_clickhouse` so it's ready to use

### 🧱 Architecture

```
┌──────────────────────────────────┐   bridge net: pgch_net   ┌────────────────────────────────┐
│ pgch-postgres                    │ ──────────────────────►  │ pgch-clickhouse                │
│   ghcr.io/clickhouse/pg_clickhouse│   binary :9000          │   clickhouse/clickhouse-server │
│   PG 18.4 + pg_clickhouse 0.3     │   http   :8123          │   ClickHouse 26.5              │
│   exposed on host :5432           │ ◄──────────────────────  │   exposed on host :8123/:9000  │
└──────────────────────────────────┘     query results        └────────────────────────────────┘
```

### 📚 Lab Details

#### 01 — Extension + Foreign Server + User Mapping ([01-extension-and-server.sql](01-extension-and-server.sql))

Installs `pg_clickhouse`, inspects the `clickhouse_fdw` foreign-data wrapper, then creates a `SERVER`, `USER MAPPING`, and performs a sanity check via `clickhouse_raw_query()`.

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
- **`binary`** — native TCP on port 9000 (recommended; faster, supports streaming)
- **`http`** — HTTP on port 8123 (more permissive over firewalls, supports TLS via `https`)

#### 02 — `IMPORT FOREIGN SCHEMA` ([02-import-foreign-schema.sql](02-import-foreign-schema.sql))

Seeds two tables (`lab.events` 100k rows, `lab.users` 1k rows) inside ClickHouse, then imports them into PostgreSQL with a single statement:

```sql
IMPORT FOREIGN SCHEMA lab FROM SERVER ch_srv INTO imported_lab;
```

Variants:

```sql
IMPORT FOREIGN SCHEMA lab LIMIT TO (events)   FROM SERVER ch_srv INTO imported_lab;
IMPORT FOREIGN SCHEMA lab EXCEPT   (users)    FROM SERVER ch_srv INTO imported_lab;
```

Type-mapping highlights:

| ClickHouse | PostgreSQL | Note |
|---|---|---|
| `UInt8` / `UInt16` | `smallint` / `integer` | |
| `UInt32` / `UInt64` | `bigint` | `UInt64` errors on overflow |
| `Int8` / `Int16` / `Int32` / `Int64` | `smallint` / `smallint` / `integer` / `bigint` | |
| `Float32` / `Float64` | `real` / `double precision` | |
| `Decimal(p,s)` | `numeric(p,s)` | |
| `Date` / `Date32` | `date` | |
| `DateTime` / `DateTime64` | `timestamptz` | |
| `String` | `text` (or `bytea` for binary) | |
| `LowCardinality(T)` | same as `T` | |
| `UUID` | `uuid` | |
| `IPv4` / `IPv6` | `inet` | |
| `Bool` | `boolean` | |
| `JSON` | `jsonb` / `json` | |

#### 03 — Pushdown demonstrations ([03-pushdown-and-aggregates.sql](03-pushdown-and-aggregates.sql))

Every `EXPLAIN (VERBOSE)` shows the **`Remote SQL`** line — the exact ClickHouse query the extension produced. This is the primary debugging tool when you want to know what ClickHouse actually executed.

Demonstrated pushdowns:
- `WHERE` with multiple predicates
- `GROUP BY` with `count`/`avg`/`sum`
- `JOIN` across two foreign tables (both joins run inside ClickHouse)
- `count(DISTINCT user_id)`
- `row_number() OVER (PARTITION BY … ORDER BY …)` window function
- `date_trunc('hour', …)` translation

Session-level ClickHouse settings can be forwarded via:

```sql
SET pg_clickhouse.session_settings = 'connect_timeout 5, max_block_size 8192';
```

The default is `'join_use_nulls 1, group_by_use_nulls 1, final 1'`.

#### 04 — Raw query + dictionaries ([04-raw-query-and-dictionary.sql](04-raw-query-and-dictionary.sql))

`clickhouse_raw_query(sql, connection_string)` is the escape hatch — send any SQL to ClickHouse and get the raw text result back:

```sql
SELECT clickhouse_raw_query(
    'SELECT version()',
    'host=clickhouse port=8123'
);
```

The lab uses it to:
1. Create a ClickHouse `MergeTree` table (`country_lookup`)
2. Map it back into PG via `CREATE FOREIGN TABLE`
3. Create a CH `DICTIONARY` (`country_dict`)
4. Demonstrate `dictGet()` pushdown when used in `WHERE`
5. Use `clickhouse_raw_query` to project dictionary attributes that don't pushdown when in the SELECT list

**Security note:** `clickhouse_raw_query` has **no `EXECUTE` privileges by default**. Only superusers can call it. `GRANT EXECUTE` selectively to roles that legitimately need ad-hoc ClickHouse access.

### 🔌 Pushdown reference (what runs on ClickHouse)

**Arithmetic / math** — `abs`, `factorial`, `mod`, `pow`/`power`, `round`, `sin`/`cos`/`tan`, `atan2`, `sinh`/`cosh`/`tanh`, `degrees`, `radians`, `pi`

**Date/time** — `date_part`, `date_trunc`, `extract`, `date`, `to_timestamp`, `to_char` (limited), `CURRENT_DATE`, `CURRENT_TIMESTAMP`, `clock_timestamp`

**String** — `btrim`, `ltrim`, `rtrim`, `concat_ws`, `lower`, `upper`, `substring`/`substr`, `length`, `reverse`, `strpos`, `md5`

**Regex** — `regexp_like`, `regexp_replace`, `regexp_split_to_array`, operators `~`, `!~`, `~*`, `!~*`

**Array** — `array_position`, `array_cat`, `array_append`, `array_prepend`, `array_remove`, `array_length`, `cardinality`, `array_to_string`, `string_to_array`, `split_part`, `array_reverse`, `array_sort`, slice `[L:U]`, contains operators `@>`/`<@`/`&&`

**JSON** — `json_extract_path_text`, `json_extract_path`, `jsonb_extract_path_text`, `jsonb_extract_path`, operators `->`, `->>`

**Aggregates** — `array_agg`, `avg`, `bit_and`, `bit_or`, `bit_xor`, `bool_and`/`every`, `bool_or`, `count`, `min`, `max`, `string_agg`, `sum`, plus CH-native: `argMax`, `argMin`, `uniq`, `uniqCombined`, `uniqExact`, `uniqHLL12`, `quantile`, `quantileExact`

**Window** — `row_number`, `rank`, `dense_rank`, `ntile`, `cume_dist`, `percent_rank`, `lead`, `lag`, `first_value`, `last_value`, `nth_value`, `min`/`max` (with OVER)

**ClickHouse-specific** — `dictGet`, `toUInt8`/`toUInt16`/`toUInt32`/`toUInt64`/`toUInt128`

### 📁 File Structure

```
pg-clickhouse-lab/
├── README.md                          # This document
├── docker-compose.yml                 # Postgres 18 + pg_clickhouse + ClickHouse 26.5
├── 00-setup.sh                        # Pull, start, healthcheck, CREATE EXTENSION
├── 01-extension-and-server.sh         # Runner for extension + server + user mapping
├── 01-extension-and-server.sql        # SQL
├── 02-import-foreign-schema.sh        # Runner (seeds CH, then imports schema)
├── 02-seed-clickhouse.sql             # CH-side seed data
├── 02-import-foreign-schema.sql       # PG-side IMPORT FOREIGN SCHEMA
├── 03-pushdown-and-aggregates.sh      # Runner
├── 03-pushdown-and-aggregates.sql     # JOIN/GROUP BY/window pushdown demos
├── 04-raw-query-and-dictionary.sh     # Runner
├── 04-raw-query-and-dictionary.sql    # clickhouse_raw_query + DICTIONARY demo
├── psql.sh                            # `docker exec -it … psql` wrapper
├── clickhouse-client.sh               # `docker exec -it … clickhouse-client` wrapper
└── cleanup.sh                         # docker compose down -v
```

### ⚠️ Known caveats (from upstream docs)

- **`COPY` uses `INSERT` internally** — the ClickHouse batch API integration is not implemented yet
- **Parameterized queries via `http` driver** have DateTime timezone issues on ClickHouse < 25.8
- **Binary data stored in `TEXT` columns** truncates at NUL bytes (use `bytea` instead)
- **Case-sensitive identifiers** must be double-quoted after `IMPORT FOREIGN SCHEMA`
- **`UInt64` overflow** raises an error rather than wrapping when projected into `bigint`
- **Frame specifications** on ranking window functions are ignored during pushdown

### 🔍 Additional resources

- [Introducing pg_clickhouse](https://clickhouse.com/blog/introducing-pg_clickhouse) — launch announcement
- [pg_clickhouse is the fastest Postgres extension on ClickBench](https://clickhouse.com/blog/pg_clickhouse-fastest-analytics-for-postgres)
- [Postgres managed by ClickHouse is now in beta](https://clickhouse.com/blog/postgres-managed-by-clickhouse-beta)
- [Reference doc (markdown)](https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/pg_clickhouse.md)
- [Tutorial doc (markdown)](https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/tutorial.md)

### 📝 Notes

- All scripts were verified end-to-end against `pg_clickhouse 0.3` on PG 18.4 with ClickHouse 26.5.1.882
- Re-running any lab script is idempotent — `IF EXISTS` guards and `DROP … CASCADE` keep state consistent
- The compose stack uses a bridge network (`pgch_net`) instead of `--network host`, so it works on macOS Docker Desktop where host networking is limited

---

**Happy Learning! 🚀**

For questions or issues, see the main [clickhouse-hols README](../../README.md).

---

## 한국어

`pg_clickhouse` PostgreSQL 익스텐션을 도커만으로 처음부터 끝까지 실습할 수 있는 자급자족 랩입니다. PostgreSQL 18 (익스텐션 사전 빌드 포함)과 ClickHouse 26.5를 비공개 도커 네트워크에 함께 띄워 — 익스텐션 설치, foreign server 등록, 스키마 임포트, 푸시다운 관찰, raw-query 사용을 모두 호스트에 아무것도 설치하지 않고 진행합니다.

### 📋 `pg_clickhouse`란?

`pg_clickhouse`는 ClickHouse가 2025년 12월에 공개한 **Apache 2.0 라이선스** PostgreSQL 익스텐션입니다. **SQL을 다시 작성하지 않고도** PostgreSQL 클라이언트에서 ClickHouse에 분석 쿼리를 실행할 수 있게 해줍니다 — 익스텐션이 각 쿼리를 파싱하고 변환 가능한 부분을 **ClickHouse에 푸시다운**해 실행하고, 최종 결과 행만 PostgreSQL로 가져옵니다.

- **레포지토리**: [ClickHouse/pg_clickhouse](https://github.com/ClickHouse/pg_clickhouse)
- **공식 문서**: [clickhouse.com/docs/integrations/pg_clickhouse](https://clickhouse.com/docs/integrations/pg_clickhouse)
- **PGXN**: [pgxn.org/dist/pg_clickhouse](https://pgxn.org/dist/pg_clickhouse)
- **사전 빌드 이미지**: `ghcr.io/clickhouse/pg_clickhouse:18` (`:17`, `:16`, `:15`, `:14`, `:13`도 제공)
- **지원**: PostgreSQL 13+ 및 ClickHouse v23+
- **라이선스**: Apache-2.0
- **2026년 1월 기준** ClickBench에서 **가장 빠른** PG 분석 익스텐션

### 🎯 이 랩에서 다루는 내용

| 단계 | 주제 | 핵심 |
|---|---|---|
| 01 | 익스텐션 + Foreign Server + User Mapping | `CREATE EXTENSION`, `CREATE SERVER`, `CREATE USER MAPPING`, `clickhouse_raw_query` |
| 02 | `IMPORT FOREIGN SCHEMA` | CH 테이블 전체를 PG foreign table로 자동 생성, 타입 매핑표 |
| 03 | 푸시다운 시연 | `EXPLAIN (VERBOSE)`로 JOIN/GROUP BY/윈도우 함수 푸시다운 확인 |
| 04 | Raw-query 탈출구 + 딕셔너리 | CH 딕셔너리 생성 후 PG에서 `dictGet` 푸시다운 |

### 🚀 빠른 시작

```bash
cd local/pg-clickhouse-lab
./00-setup.sh

# 랩 진행
./01-extension-and-server.sh
./02-import-foreign-schema.sh
./03-pushdown-and-aggregates.sh
./04-raw-query-and-dictionary.sh

# 인터랙티브 셸
./psql.sh                    # pgch-postgres에 psql 접속
./clickhouse-client.sh       # pgch-clickhouse에 clickhouse-client 접속

# 전부 정리
./cleanup.sh
```

`00-setup.sh`는 다음을 수행합니다:
1. `ghcr.io/clickhouse/pg_clickhouse:18`과 `clickhouse/clickhouse-server:26.5` 이미지 pull
2. 비공개 브리지 네트워크 (`pgch_net`)에서 두 컨테이너 기동
3. 둘 다 healthy 상태가 될 때까지 대기
4. `CREATE EXTENSION pg_clickhouse` 실행해 사용 준비 완료

### 🧱 아키텍처

```
┌──────────────────────────────────┐   pgch_net (bridge)     ┌────────────────────────────────┐
│ pgch-postgres                    │ ──────────────────────► │ pgch-clickhouse                │
│   ghcr.io/clickhouse/pg_clickhouse│   binary :9000         │   clickhouse/clickhouse-server │
│   PG 18.4 + pg_clickhouse 0.3     │   http   :8123         │   ClickHouse 26.5              │
│   호스트 노출 :5432               │ ◄────────────────────── │   호스트 노출 :8123/:9000      │
└──────────────────────────────────┘     쿼리 결과            └────────────────────────────────┘
```

### 📚 랩 상세

#### 01 — 익스텐션 + Foreign Server + User Mapping ([01-extension-and-server.sql](01-extension-and-server.sql))

`pg_clickhouse`를 설치하고 `clickhouse_fdw` foreign-data wrapper를 확인한 뒤, `SERVER`와 `USER MAPPING`을 생성합니다. `clickhouse_raw_query()`로 연결 확인까지 진행합니다.

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
- **`binary`** — 9000번 포트 네이티브 TCP (권장; 빠르고 스트리밍 지원)
- **`http`** — 8123번 포트 HTTP (방화벽 환경에 유리, `https`로 TLS 지원)

#### 02 — `IMPORT FOREIGN SCHEMA` ([02-import-foreign-schema.sql](02-import-foreign-schema.sql))

ClickHouse에 두 테이블 (`lab.events` 10만 행, `lab.users` 1천 행)을 시드한 뒤, 한 줄로 PostgreSQL로 임포트합니다:

```sql
IMPORT FOREIGN SCHEMA lab FROM SERVER ch_srv INTO imported_lab;
```

변형 구문:

```sql
IMPORT FOREIGN SCHEMA lab LIMIT TO (events)   FROM SERVER ch_srv INTO imported_lab;
IMPORT FOREIGN SCHEMA lab EXCEPT   (users)    FROM SERVER ch_srv INTO imported_lab;
```

타입 매핑 요약:

| ClickHouse | PostgreSQL | 비고 |
|---|---|---|
| `UInt8` / `UInt16` | `smallint` / `integer` | |
| `UInt32` / `UInt64` | `bigint` | `UInt64`는 오버플로 시 오류 |
| `Int8` / `Int16` / `Int32` / `Int64` | `smallint` / `smallint` / `integer` / `bigint` | |
| `Float32` / `Float64` | `real` / `double precision` | |
| `Decimal(p,s)` | `numeric(p,s)` | |
| `Date` / `Date32` | `date` | |
| `DateTime` / `DateTime64` | `timestamptz` | |
| `String` | `text` (바이너리는 `bytea`) | |
| `LowCardinality(T)` | `T`와 동일 | |
| `UUID` | `uuid` | |
| `IPv4` / `IPv6` | `inet` | |
| `Bool` | `boolean` | |
| `JSON` | `jsonb` / `json` | |

#### 03 — 푸시다운 시연 ([03-pushdown-and-aggregates.sql](03-pushdown-and-aggregates.sql))

모든 `EXPLAIN (VERBOSE)`은 **`Remote SQL`** 줄을 보여줍니다 — 익스텐션이 실제로 ClickHouse로 보낸 쿼리입니다. ClickHouse가 무엇을 수행했는지 디버깅할 때 일차적으로 확인할 출력입니다.

시연되는 푸시다운:
- 여러 조건의 `WHERE`
- `GROUP BY` + `count`/`avg`/`sum`
- 두 foreign table간 `JOIN` (조인이 ClickHouse 내부에서 실행됨)
- `count(DISTINCT user_id)`
- `row_number() OVER (PARTITION BY … ORDER BY …)` 윈도우 함수
- `date_trunc('hour', …)` 변환

세션 단위로 ClickHouse 설정을 전달할 수 있습니다:

```sql
SET pg_clickhouse.session_settings = 'connect_timeout 5, max_block_size 8192';
```

기본값은 `'join_use_nulls 1, group_by_use_nulls 1, final 1'`입니다.

#### 04 — Raw query + 딕셔너리 ([04-raw-query-and-dictionary.sql](04-raw-query-and-dictionary.sql))

`clickhouse_raw_query(sql, connection_string)`는 탈출구입니다 — 임의의 SQL을 ClickHouse로 보내 원본 텍스트 결과를 받습니다:

```sql
SELECT clickhouse_raw_query(
    'SELECT version()',
    'host=clickhouse port=8123'
);
```

랩에서는 이를 사용해:
1. ClickHouse `MergeTree` 테이블 (`country_lookup`) 생성
2. `CREATE FOREIGN TABLE`로 PG에 매핑
3. CH `DICTIONARY` (`country_dict`) 생성
4. `WHERE`에서 `dictGet()` 푸시다운 시연
5. SELECT 리스트에서 푸시다운되지 않는 딕셔너리 속성은 `clickhouse_raw_query`로 우회

**보안 노트:** `clickhouse_raw_query`는 **기본적으로 `EXECUTE` 권한이 없습니다**. 슈퍼유저만 호출 가능합니다. 정당하게 ad-hoc ClickHouse 접근이 필요한 역할에만 `GRANT EXECUTE`를 부여하세요.

### 🔌 푸시다운 레퍼런스 (ClickHouse에서 실행되는 항목)

**산술/수학** — `abs`, `factorial`, `mod`, `pow`/`power`, `round`, `sin`/`cos`/`tan`, `atan2`, `sinh`/`cosh`/`tanh`, `degrees`, `radians`, `pi`

**날짜/시간** — `date_part`, `date_trunc`, `extract`, `date`, `to_timestamp`, `to_char` (제한적), `CURRENT_DATE`, `CURRENT_TIMESTAMP`, `clock_timestamp`

**문자열** — `btrim`, `ltrim`, `rtrim`, `concat_ws`, `lower`, `upper`, `substring`/`substr`, `length`, `reverse`, `strpos`, `md5`

**정규식** — `regexp_like`, `regexp_replace`, `regexp_split_to_array`, 연산자 `~`, `!~`, `~*`, `!~*`

**배열** — `array_position`, `array_cat`, `array_append`, `array_prepend`, `array_remove`, `array_length`, `cardinality`, `array_to_string`, `string_to_array`, `split_part`, `array_reverse`, `array_sort`, 슬라이스 `[L:U]`, 포함 연산자 `@>`/`<@`/`&&`

**JSON** — `json_extract_path_text`, `json_extract_path`, `jsonb_extract_path_text`, `jsonb_extract_path`, 연산자 `->`, `->>`

**집계** — `array_agg`, `avg`, `bit_and`, `bit_or`, `bit_xor`, `bool_and`/`every`, `bool_or`, `count`, `min`, `max`, `string_agg`, `sum`, 그리고 CH 네이티브: `argMax`, `argMin`, `uniq`, `uniqCombined`, `uniqExact`, `uniqHLL12`, `quantile`, `quantileExact`

**윈도우** — `row_number`, `rank`, `dense_rank`, `ntile`, `cume_dist`, `percent_rank`, `lead`, `lag`, `first_value`, `last_value`, `nth_value`, `min`/`max` (OVER 절과 함께)

**ClickHouse 전용** — `dictGet`, `toUInt8`/`toUInt16`/`toUInt32`/`toUInt64`/`toUInt128`

### 📁 파일 구조

```
pg-clickhouse-lab/
├── README.md                          # 이 문서
├── docker-compose.yml                 # PG 18 + pg_clickhouse + CH 26.5
├── 00-setup.sh                        # 이미지 pull, 기동, 헬스체크, CREATE EXTENSION
├── 01-extension-and-server.sh         # 익스텐션 + 서버 + 매핑 러너
├── 01-extension-and-server.sql        # SQL
├── 02-import-foreign-schema.sh        # 러너 (CH 시드 후 IMPORT)
├── 02-seed-clickhouse.sql             # CH 쪽 시드 데이터
├── 02-import-foreign-schema.sql       # PG 쪽 IMPORT FOREIGN SCHEMA
├── 03-pushdown-and-aggregates.sh      # 러너
├── 03-pushdown-and-aggregates.sql     # JOIN/GROUP BY/윈도우 푸시다운 시연
├── 04-raw-query-and-dictionary.sh     # 러너
├── 04-raw-query-and-dictionary.sql    # clickhouse_raw_query + DICTIONARY 시연
├── psql.sh                            # `docker exec -it … psql` 래퍼
├── clickhouse-client.sh               # `docker exec -it … clickhouse-client` 래퍼
└── cleanup.sh                         # docker compose down -v
```

### ⚠️ 알려진 제약 (업스트림 문서 기준)

- **`COPY`는 내부적으로 `INSERT` 사용** — ClickHouse 배치 API 연동 미구현
- **`http` 드라이버 + 파라미터화 쿼리**는 ClickHouse < 25.8에서 DateTime 타임존 이슈
- **`TEXT` 컬럼에 바이너리 저장 시** NUL 바이트에서 잘림 (`bytea` 사용 권장)
- **대소문자 구분 식별자**는 `IMPORT FOREIGN SCHEMA` 후 큰따옴표로 감싸야 함
- **`UInt64` 오버플로**는 `bigint`로 투영 시 래핑 대신 오류 발생
- **랭킹 윈도우 함수의 프레임 명세**는 푸시다운 시 무시됨

### 🔍 추가 자료

- [Introducing pg_clickhouse](https://clickhouse.com/blog/introducing-pg_clickhouse) — 출시 공지
- [pg_clickhouse is the fastest Postgres extension on ClickBench](https://clickhouse.com/blog/pg_clickhouse-fastest-analytics-for-postgres)
- [Postgres managed by ClickHouse is now in beta](https://clickhouse.com/blog/postgres-managed-by-clickhouse-beta)
- [Reference doc (markdown)](https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/pg_clickhouse.md)
- [Tutorial doc (markdown)](https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/tutorial.md)

### 📝 참고사항

- 모든 스크립트는 `pg_clickhouse 0.3` (PG 18.4) + ClickHouse 26.5.1.882에서 end-to-end 검증됨
- 모든 랩 스크립트는 멱등성 보장 — `IF EXISTS`와 `DROP … CASCADE`로 상태 일관성 유지
- 컴포즈 스택은 `--network host` 대신 브리지 네트워크 (`pgch_net`)를 사용해 macOS Docker Desktop에서도 동작

---

**Happy Learning! 🚀**

질문이나 이슈는 메인 [clickhouse-hols README](../../README.md)를 참조하세요.
