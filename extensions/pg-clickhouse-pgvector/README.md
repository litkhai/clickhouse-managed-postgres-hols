# pgvector through pg_clickhouse — nearest-neighbour search pushed down to ClickHouse

[English](#english) | [한국어](#한국어)

---

## English

From version 0.11.1 (2026-11-09), `pg_clickhouse` maps a pgvector `vector` column onto a ClickHouse
`Array(Float32)` column and pushes the pgvector distance operators down. A Postgres application can then
run `ORDER BY emb <=> $1 LIMIT 10` against a foreign table, and ClickHouse answers it from its own HNSW
`vector_similarity` index. `EXPLAIN` says whether that index can be used, and why not when it can't.

This lab checks those claims on real embeddings. It runs PostgreSQL 18, pg_clickhouse 0.11.1 and
pgvector 0.8.7 next to ClickHouse 26.9.7.9 in local Docker. The data is 254,158 Hacker News comments and
stories with 384-dimension all-MiniLM-L6-v2 embeddings from ClickHouse's public dataset, plus 100
held-out query vectors. It covers four questions:

1. Which query shapes push down, and which of them can use the index (EXPLAIN).
2. Whether ClickHouse really searched the index (`system.query_log`).
3. What recall@10 the index gives, compared with an exact search and with a local pgvector HNSW index.
4. What the round trip through the foreign table costs.

> **Status: run end to end from a clean stack on 2026-11-20, 00:26–00:42 UTC** (`cleanup.sh`, then 00–04;
> macOS, Docker Desktop on Apple silicon, VM 12 CPUs / 15.6 GiB) against PostgreSQL 18.7, pg_clickhouse 0.11.1
> (`pgch_version()`), pgvector 0.8.7 and ClickHouse 26.9.7.9. Every number below comes from that run unless
> marked otherwise.

How this differs from the other vector lab in this repository:
[managed-postgres/vector-search](../../managed-postgres/vector-search/) compares pgvector, VectorChord and
ClickHouse's index **side by side**, and uses `pg_clickhouse` only to move rows. Here the queries **run
through** `pg_clickhouse`. The general pg_clickhouse walk-through is in [pg-clickhouse-lab](../pg-clickhouse-lab/)
(verified on 0.11.0; this lab needs 0.11.1).

### 🎯 What this lab covers

| Step | Topic | Highlights |
|---|---|---|
| 00 | Setup | PG 18 + pg_clickhouse 0.11.1 + pgvector 0.8.7 image, ClickHouse 26.9.7.9 |
| 01 | Load | 300,100 rows from the public Parquet file, cleaned to 254,158 documents + 100 queries; HNSW index in ClickHouse; exact top 10 per query; a local pgvector copy with its own HNSW index |
| 02 | Pushdown shapes | `EXPLAIN (VERBOSE)` for nine shapes: index used, metric mismatch, farthest first, no LIMIT, LIMIT above the cap, distance in `WHERE`, distance in the select list |
| 03 | Index use in `system.query_log` | `USearchSearchCount` and rows read per shape, tagged with `log_comment` through `pg_clickhouse.session_settings` |
| 04 | Recall and latency | recall@10, p50 and p95: the ClickHouse index through the foreign table and through `clickhouse_query()`, an exact ClickHouse scan, and local pgvector (HNSW at two `ef_search` values, and exact) |

### 🚀 Quick Start

```bash
./00-setup.sh              # build and start both containers
./01-load.sh               # one-time download (about 14 minutes from Seoul), then index and truth
./02-pushdown-shapes.sh
./03-index-in-query-log.sh
./04-recall-latency.sh     # about 30 seconds

./psql.sh                  # interactive psql
./clickhouse-client.sh     # interactive clickhouse-client; the Play UI is at http://localhost:18123/play
./cleanup.sh               # remove containers and volumes
```

Ports differ from `pg-clickhouse-lab` (Postgres 15432, ClickHouse 18123 / 19000), so both labs can run at once.
`ROWS=100100 ./01-load.sh` downloads a smaller slice.

### 🧱 Architecture

```text
 psql ──► PostgreSQL 18.7 (pgvec-postgres)                 ClickHouse 26.9.7.9 (pgvec-clickhouse)
          ├─ pgvector 0.8.7                                ├─ hn_docs  Array(Float32) + INDEX ann
          ├─ pg_clickhouse 0.11.1 ── binary protocol ───►  │           vector_similarity('hnsw', 'cosineDistance', 384)
          │    foreign tables hn_docs, hn_queries, hn_truth├─ hn_queries (100 held-out vectors)
          └─ hn_docs_local + HNSW (vector_cosine_ops)      └─ hn_truth  (exact top 10 per query)
```

### 📚 Lab Details

#### 01 — Load ([01-load.sh](01-load.sh), [01-load-clickhouse.sql](01-load-clickhouse.sql), [01-postgres-objects.sql](01-postgres-objects.sql))

The dataset is one 59 GB Parquet file in a public bucket
(`s3://clickhouse-datasets/hackernews-miniLM/hackernews_part_1_of_1.parquet`, read with `NOSIGN`).
ClickHouse reads only what the `LIMIT` needs, but from Seoul the 300,100-row slice still took
**12 min 34 s** in the verified run (13 min 52 s in an earlier one). The rows stay in `hn_raw`, and a re-run skips the download.

One row in eight of the slice is a comment or story with no text (`"<by>: "`), and those rows share a
handful of identical vectors. Kept: rows with at least 60 characters, one per distinct vector. That
leaves 254,258 rows, split into 100 queries (first 100 by `cityHash64(id)`) and 254,158 documents.
The slice is not the same from run to run: ClickHouse reads the Parquet row groups in parallel, so
`LIMIT` keeps whichever rows arrive first. An earlier run the same day kept 254,664 documents and
measured close to the numbers below (step 04: `ch_index` recall 0.998, p50 41.46 ms;
`ch_query_ids` 0.997, 3.04 ms).

| Object | Where | Size / time (2026-11-20) |
|---|---|---|
| `hn_docs` with `INDEX ann … vector_similarity('hnsw', 'cosineDistance', 384)` (defaults: `bf16`, M 32, ef_construction 128, GRANULARITY 100 million), after `OPTIMIZE … FINAL` | ClickHouse | 1 part, index 169.27 MiB |
| `hn_truth`: exact cosine top 10 per query (`groupArraySorted` over a cross join) | ClickHouse | ClickHouse script 45.1 s in total |
| `hn_docs_local`: `CREATE TABLE … AS SELECT id, emb FROM hn_docs` through the foreign table | Postgres | 254,158 rows in 2.4 s |
| `hnsw (emb vector_cosine_ops) WITH (m = 32, ef_construction = 128)` | Postgres | built in 89.6 s, 515 MB |

The pgvector build needs the graph in `maintenance_work_mem` (2 GB here). With 4 parallel workers, the
build also needs shared memory: with `shm_size: 1g` it failed with
`could not resize shared memory segment … No space left on device`. The compose file sets 3 GB.

#### 02 — Pushdown shapes ([02-pushdown-shapes.sql](02-pushdown-shapes.sql))

The query vector comes from a sub-select (`(SELECT emb FROM hn_queries WHERE qid = 1)`). pg_clickhouse
runs it as an InitPlan and sends the vector as a typed parameter: `{p1:Array(Float32)}`. A literal or
a prepared-statement parameter is sent as `cast([…] as Array(Float32))` instead, with the same plan.

```text
Foreign Scan on public.hn_docs
  Output: hn_docs.id, hn_docs.title, (hn_docs.emb <=> (InitPlan 1).col1)
  Vector Search: cosineDistance on emb
  Vector Index: ann
  Remote SQL: SELECT id, title, emb FROM default.hn_docs ORDER BY cosineDistance(emb, {p1:Array(Float32)}) ASC NULLS LAST LIMIT 10
```

| Shape | Remote SQL | EXPLAIN |
|---|---|---|
| A `ORDER BY emb <=> q LIMIT 10` | `ORDER BY cosineDistance(…) ASC … LIMIT 10` | `Vector Index: ann` |
| B same, with `WHERE type = 1` | filter and ORDER BY / LIMIT both pushed | `Vector Index: ann` |
| C `ORDER BY emb <-> q LIMIT 10` (L2 on a cosine index) | `L2Distance` | `Vector Index Not Used: index "ann" uses cosineDistance (<=>), not L2Distance` |
| D `ORDER BY emb <#> q LIMIT 10` | `dotProduct(…) DESC` | not used: the index is cosine |
| E `ORDER BY emb <=> q DESC LIMIT 10` | `DESC NULLS FIRST` | not used, plus `WARNING … the ORDER BY sorts farthest first` |
| F `ORDER BY emb <=> q` (no LIMIT) | no LIMIT | not used, plus `WARNING … the query has no LIMIT` |
| G `LIMIT 2000` | `LIMIT 2000` | `Vector Index Not Used: LIMIT 2000 exceeds max_limit_for_vector_search_queries (1000)` (no warning) |
| H `WHERE emb <=> q < 0.5 GROUP BY type` | the whole aggregate, `cosineDistance(…) < 0.5` | aggregate pushdown; exact |
| I `cosine_distance(emb, q)`, `vector_dims(emb)` in the select list | `SELECT id, emb …` | **computed in Postgres** |

What to take from it:

- **The distance in the select list is computed in Postgres.** For A, the Remote SQL selects `emb`
  itself, and Postgres computes `<=>` again for the 10 rows. With a LIMIT that is 10 vectors. In shape
  I, with no LIMIT, every matching vector (1.5 KB each at 384 dimensions) travels to Postgres. The same
  functions do push down inside `WHERE` (H).
- **The operator has to match the index.** `<=>` needs a `cosineDistance` index and `<->` an
  `L2Distance` index. `<#>` sorts as `dotProduct … DESC`, the form a `dotProduct` index serves (per the ClickHouse docs and
  the release notes; not run here). Build the
  ClickHouse index for the operator your application sends.
- **The cap is a ClickHouse setting.** `max_limit_for_vector_search_queries` is 1000 in 26.9.7.9
  (`system.settings`); pg_clickhouse reads it and explains a larger LIMIT, but prints no warning for it.
  Run for real, `LIMIT 2000` returned its rows from an exact scan (no HNSW search, 254,158 rows read,
  189 ms) rather than an error, and `LIMIT 1000` used the index but read 246,449 rows (120 ms).

#### 03 — Index use in `system.query_log` ([03-index-in-query-log.sql](03-index-in-query-log.sql))

Each query is tagged with `SET pg_clickhouse.session_settings = 'log_comment …'`. Since 0.11.1 this GUC
overrides built-in settings **by key**, so the tag no longer drops `final 1` or `join_use_nulls 1`
(`Settings['final']` is `1` on every row below). On 0.11.0 the same `SET` replaced them; see
step 06 of [pg-clickhouse-lab](../pg-clickhouse-lab/).
The log is read back from Postgres with `clickhouse_query()`.

| Tag (2026-11-20) | `USearchSearchCount` | rows read | ms |
|---|---|---|---|
| a: cosine, LIMIT 10 | **1** | 30,583 | 44 |
| b: cosine, `WHERE type = 1` (4.6 % of rows), LIMIT 10 | **1** | 30,583 | 41 |
| c: L2 on the cosine index | 0 | 254,158 | 51 |
| d: farthest first | 0 | 254,158 | 54 |
| e: cosine with `use_skip_indexes 0` | 0 | 254,158 | 52 |

EXPLAIN predicted every row. The filtered search (b) returned its 10 rows; recall under filters was not measured.

#### 04 — Recall and latency ([04-recall-latency.sql](04-recall-latency.sql))

The 100 held-out vectors run through six methods. Each method runs every query twice and only the second
pass is timed, as wall-clock time in the Postgres backend, so the `ch_*` rows include the round trip to
ClickHouse. Recall is against `hn_truth`.

| Method (2026-11-20) | How | recall@10 | p50 ms | p95 ms |
|---|---|---|---|---|
| `ch_index` | foreign table, `ORDER BY emb <=> $1 LIMIT 10` | 0.996 | 46.39 | 59.14 |
| `ch_exact` | same, `use_skip_indexes 0` | 1.000 | 54.07 | 59.19 |
| `ch_query_ids` | `clickhouse_query()`, same search selecting only `id` | 0.995 | **3.39** | 5.41 |
| `pg_hnsw_ef40` | local pgvector HNSW, `hnsw.ef_search = 40` (default) | 0.977 | 2.97 | 3.94 |
| `pg_hnsw_ef256` | local pgvector HNSW, `hnsw.ef_search = 256` (ClickHouse's search default) | 0.999 | 14.60 | 23.64 |
| `pg_exact` | local, index scans off | 1.000 | 29.56 | 32.41 |

On the ClickHouse side (`system.query_log`, same pass; the bytes column was added to the script after the
clean run and checked on a re-run of step 04, and its values here are the clean run's, read in the Play UI):

| Tag | p50 ms | p95 ms | HNSW searches | avg rows read | avg bytes read |
|---|---|---|---|---|---|
| `pgvec_04_ch_index` | 45 | 59 | 100 | 58,761 | 43.64 MiB |
| `pgvec_04_ch_query_ids` | **3** | 4 | 100 | 58,761 | 525.29 KiB |
| `pgvec_04_ch_exact` | 53 | 59 | 0 | 283,541 | 376.33 MiB |

**The index search is fast; fetching the vector column is not.** `ch_index` and `ch_query_ids` run the
same HNSW search (100 searches, the same rows read) and differ only in the select list. The plan's
`Output` computes `emb <=> $1` in Postgres for the rows that come back (shape A in step 02), so
pg_clickhouse sends `SELECT id, emb …`, and ClickHouse reads the `emb` column of every granule the
index points into. Over the 100 queries, `read_bytes` averaged 43.64 MiB for `ch_index` and 525.29 KiB for
`ch_query_ids` (`system.query_log`, same pass). Run directly in ClickHouse, one search read 45.84 MiB
with `id, emb` and 700.12 KiB with `id` alone (three runs each, median 54 ms against 4 ms). The time is in ClickHouse, not on the wire:
the Postgres-side p50 is within about 1 ms of the ClickHouse-side p50 for both methods.

So for a latency-sensitive path, send the id-only query through `clickhouse_query()` (as `ch_query_ids`
does) and join the rest in Postgres. The foreign-table form keeps plain SQL and still uses the index.

At these settings the ClickHouse index (`bf16`, `ef_search` 256) reached 0.995–0.996, and pgvector
reached 0.977 at its default `ef_search` 40 and 0.999 at 256. This compares one configuration of each
on 254,158 vectors on one laptop. For a comparison at matched recall on a million vectors, see
[managed-postgres/vector-search](../../managed-postgres/vector-search/).

### 📁 File Structure

```text
pg-clickhouse-pgvector/
├── docker-compose.yml          # ClickHouse 26.9.7.9 + Postgres (built), ports 15432 / 18123 / 19000
├── postgres/Dockerfile         # ghcr.io/clickhouse/pg_clickhouse:18-0.11.1 + postgresql-18-pgvector 0.8.7
├── 00-setup.sh
├── 01-load.sh                  # download (once), then the two SQL files below
├── 01-load-clickhouse.sql      # clean, split, HNSW index, ground truth
├── 01-postgres-objects.sql     # foreign server and tables, local pgvector copy + HNSW
├── 02-pushdown-shapes.sh/.sql
├── 03-index-in-query-log.sh/.sql
├── 04-recall-latency.sh/.sql
├── psql.sh · clickhouse-client.sh · cleanup.sh
└── README.md
```

### 🔍 Sources

- [pg_clickhouse v0.11.1 release notes](https://github.com/ClickHouse/pg_clickhouse/releases/tag/v0.11.1) (read 2026-11-20)
- [ClickHouse docs — Exact and Approximate Vector Search](https://clickhouse.com/docs/engines/table-engines/mergetree-family/annindexes) (read 2026-11-20). Where the page and the 26.9.7.9 build differ, this lab uses `system.settings`: `max_limit_for_vector_search_queries` 1000 and `vector_search_with_rescoring` 0 there.
- [pgvector v0.8.7 README](https://github.com/pgvector/pgvector/blob/v0.8.7/README.md) (read 2026-11-20)
- [ClickHouse docs — Hacker News vector search dataset](https://clickhouse.com/docs/get-started/sample-datasets/hacker-news-vector-search)

---

## 한국어

`pg_clickhouse` 0.11.1(2026-11-09)부터 pgvector의 `vector` 컬럼을 ClickHouse의 `Array(Float32)` 컬럼에
대응시키고, pgvector 거리 연산자를 ClickHouse로 푸시다운합니다. 그래서 Postgres 애플리케이션이 외부 테이블에
`ORDER BY emb <=> $1 LIMIT 10`을 보내면, ClickHouse가 자기 HNSW `vector_similarity` 인덱스로 답합니다.
그 인덱스를 쓸 수 있는지, 못 쓰면 왜인지는 `EXPLAIN`에 나옵니다.

이 랩은 이 내용을 실제 임베딩으로 확인합니다. 로컬 Docker에서 PostgreSQL 18, pg_clickhouse 0.11.1,
pgvector 0.8.7과 ClickHouse 26.9.7.9를 함께 띄웁니다. 데이터는 ClickHouse 공개 데이터셋의 Hacker News 댓글·글
254,158건(all-MiniLM-L6-v2, 384차원)과, 따로 떼어 둔 질의 벡터 100개입니다. 다음 네 가지를 봅니다.

1. 어떤 질의 형태가 푸시다운되고, 그중 어떤 것이 인덱스를 쓸 수 있는가(EXPLAIN)
2. ClickHouse가 실제로 인덱스를 검색했는가(`system.query_log`)
3. 인덱스의 recall@10은 얼마인가: 정확 검색, 로컬 pgvector HNSW 인덱스와 비교
4. 외부 테이블을 거치는 비용은 얼마인가

> **상태: 2026-11-20 00:26–00:42 UTC, 빈 스택에서 처음부터 끝까지 실행함**(`cleanup.sh` 후 00–04, macOS, Apple silicon의
> Docker Desktop, VM 12 CPU / 15.6 GiB). PostgreSQL 18.7, pg_clickhouse 0.11.1(`pgch_version()`), pgvector 0.8.7,
> ClickHouse 26.9.7.9. 따로 적지 않은 숫자는 모두 그 실행에서 나왔습니다.

이 저장소의 다른 벡터 랩과의 차이:
[managed-postgres/vector-search](../../managed-postgres/vector-search/)는 pgvector, VectorChord, ClickHouse 인덱스를
**나란히** 비교하고, `pg_clickhouse`는 행을 옮기는 데만 씁니다. 이 랩은 질의가 `pg_clickhouse`를 **거쳐서**
실행됩니다. pg_clickhouse 전반은 [pg-clickhouse-lab](../pg-clickhouse-lab/)에 있습니다(0.11.0에서 검증, 이 랩은
0.11.1이 필요합니다).

### 🎯 이 랩에서 다루는 내용

| 단계 | 주제 | 핵심 |
|---|---|---|
| 00 | 준비 | PG 18 + pg_clickhouse 0.11.1 + pgvector 0.8.7 이미지, ClickHouse 26.9.7.9 |
| 01 | 적재 | 공개 Parquet에서 300,100행을 받아 문서 254,158건 + 질의 100개로 정리, ClickHouse HNSW 인덱스, 질의별 정확한 top 10, 자체 HNSW 인덱스를 가진 로컬 pgvector 사본 |
| 02 | 푸시다운 형태 | 아홉 가지 형태의 `EXPLAIN (VERBOSE)`: 인덱스 사용, 거리 함수 불일치, 먼 순서, LIMIT 없음, 상한 초과 LIMIT, `WHERE` 안의 거리, SELECT 목록의 거리 |
| 03 | `system.query_log`로 인덱스 사용 확인 | 형태별 `USearchSearchCount`와 읽은 행 수, `pg_clickhouse.session_settings`의 `log_comment`로 태그 |
| 04 | recall과 지연 시간 | recall@10, p50, p95: 외부 테이블과 `clickhouse_query()`로 쓴 ClickHouse 인덱스, ClickHouse 정확 스캔, 로컬 pgvector(`ef_search` 두 값의 HNSW, 정확 검색) |

### 🚀 빠른 시작

```bash
./00-setup.sh              # 컨테이너 둘을 빌드하고 띄움
./01-load.sh               # 한 번만 내려받음(서울에서 약 14분), 이어서 인덱스와 정답
./02-pushdown-shapes.sh
./03-index-in-query-log.sh
./04-recall-latency.sh     # 약 30초

./psql.sh                  # psql 셸
./clickhouse-client.sh     # clickhouse-client 셸, Play UI는 http://localhost:18123/play
./cleanup.sh               # 컨테이너와 볼륨 삭제
```

포트가 `pg-clickhouse-lab`과 다르므로(Postgres 15432, ClickHouse 18123 / 19000) 두 랩을 함께 띄울 수 있습니다.
`ROWS=100100 ./01-load.sh`로 더 작게 받을 수 있습니다.

### 🧱 아키텍처

```text
 psql ──► PostgreSQL 18.7 (pgvec-postgres)                 ClickHouse 26.9.7.9 (pgvec-clickhouse)
          ├─ pgvector 0.8.7                                ├─ hn_docs  Array(Float32) + INDEX ann
          ├─ pg_clickhouse 0.11.1 ── binary protocol ───►  │           vector_similarity('hnsw', 'cosineDistance', 384)
          │    외부 테이블 hn_docs, hn_queries, hn_truth    ├─ hn_queries (따로 떼어 둔 벡터 100개)
          └─ hn_docs_local + HNSW (vector_cosine_ops)      └─ hn_truth  (질의별 정확한 top 10)
```

### 📚 랩 상세

#### 01 — 적재 ([01-load.sh](01-load.sh), [01-load-clickhouse.sql](01-load-clickhouse.sql), [01-postgres-objects.sql](01-postgres-objects.sql))

데이터셋은 공개 버킷의 59 GB짜리 Parquet 파일 하나입니다
(`s3://clickhouse-datasets/hackernews-miniLM/hackernews_part_1_of_1.parquet`, `NOSIGN`으로 읽음).
ClickHouse는 `LIMIT`에 필요한 만큼만 읽지만, 서울에서 300,100행을 받는 데 **12분 34초**(검증 실행, 앞선 실행은 13분 52초)가
걸렸습니다. 받은 행은 `hn_raw`에 남고, 다시 실행하면 내려받기를 건너뜁니다.

받은 행의 8분의 1쯤은 본문이 없는 댓글·글(`"<by>: "`)이고, 이 행들은 똑같은 벡터 몇 개를 나눠 갖습니다.
본문이 60자 이상인 행만, 서로 다른 벡터마다 한 행씩 남겼습니다. 남은 254,258행을 질의 100개
(`cityHash64(id)` 순으로 앞의 100개)와 문서 254,158건으로 나눴습니다. 받는 행은 실행마다 조금씩 다릅니다.
ClickHouse가 Parquet 행 그룹을 병렬로 읽어서, `LIMIT`이 먼저 도착한 행을 남기기 때문입니다. 같은 날 앞선 실행은
문서 254,664건이었고 아래와 비슷한 결과였습니다(04단계: `ch_index` recall 0.998, p50 41.46 ms,
`ch_query_ids` 0.997, 3.04 ms).

| 객체 | 위치 | 크기 / 시간(2026-11-20) |
|---|---|---|
| `INDEX ann … vector_similarity('hnsw', 'cosineDistance', 384)`가 있는 `hn_docs`(기본값: `bf16`, M 32, ef_construction 128, GRANULARITY 1억), `OPTIMIZE … FINAL` 후 | ClickHouse | 파트 1개, 인덱스 169.27 MiB |
| `hn_truth`: 질의별 정확한 코사인 top 10(교차 조인에 `groupArraySorted`) | ClickHouse | ClickHouse 스크립트 전체 45.1초 |
| `hn_docs_local`: 외부 테이블로 `CREATE TABLE … AS SELECT id, emb FROM hn_docs` | Postgres | 254,158행, 2.4초 |
| `hnsw (emb vector_cosine_ops) WITH (m = 32, ef_construction = 128)` | Postgres | 빌드 89.6초, 515 MB |

pgvector 빌드는 그래프가 `maintenance_work_mem`(여기서는 2 GB)에 들어가야 빠릅니다. 병렬 작업자 4개로 빌드하면
공유 메모리도 필요합니다. `shm_size: 1g`에서는 `could not resize shared memory segment … No space left on device`로
실패했고, compose 파일은 3 GB로 잡습니다.

#### 02 — 푸시다운 형태 ([02-pushdown-shapes.sql](02-pushdown-shapes.sql))

질의 벡터는 하위 SELECT(`(SELECT emb FROM hn_queries WHERE qid = 1)`)에서 가져옵니다. pg_clickhouse는 이를
InitPlan으로 실행하고 벡터를 타입이 붙은 파라미터 `{p1:Array(Float32)}`로 보냅니다. 리터럴이나 prepared
statement 파라미터는 `cast([…] as Array(Float32))`로 보내며, 계획은 같습니다.

```text
Foreign Scan on public.hn_docs
  Output: hn_docs.id, hn_docs.title, (hn_docs.emb <=> (InitPlan 1).col1)
  Vector Search: cosineDistance on emb
  Vector Index: ann
  Remote SQL: SELECT id, title, emb FROM default.hn_docs ORDER BY cosineDistance(emb, {p1:Array(Float32)}) ASC NULLS LAST LIMIT 10
```

| 형태 | Remote SQL | EXPLAIN |
|---|---|---|
| A `ORDER BY emb <=> q LIMIT 10` | `ORDER BY cosineDistance(…) ASC … LIMIT 10` | `Vector Index: ann` |
| B 같은 검색 + `WHERE type = 1` | 필터와 ORDER BY / LIMIT 모두 푸시다운 | `Vector Index: ann` |
| C `ORDER BY emb <-> q LIMIT 10`(코사인 인덱스에 L2) | `L2Distance` | `Vector Index Not Used: index "ann" uses cosineDistance (<=>), not L2Distance` |
| D `ORDER BY emb <#> q LIMIT 10` | `dotProduct(…) DESC` | 사용 안 함: 인덱스가 코사인 |
| E `ORDER BY emb <=> q DESC LIMIT 10` | `DESC NULLS FIRST` | 사용 안 함, `WARNING … the ORDER BY sorts farthest first` |
| F `ORDER BY emb <=> q`(LIMIT 없음) | LIMIT 없음 | 사용 안 함, `WARNING … the query has no LIMIT` |
| G `LIMIT 2000` | `LIMIT 2000` | `Vector Index Not Used: LIMIT 2000 exceeds max_limit_for_vector_search_queries (1000)`(경고 없음) |
| H `WHERE emb <=> q < 0.5 GROUP BY type` | 집계 전체, `cosineDistance(…) < 0.5` | 집계 푸시다운, 정확 검색 |
| I SELECT 목록의 `cosine_distance(emb, q)`, `vector_dims(emb)` | `SELECT id, emb …` | **Postgres에서 계산** |

정리하면:

- **SELECT 목록의 거리는 Postgres가 계산합니다.** A에서도 Remote SQL은 `emb` 자체를 가져오고, Postgres가 10행에
  대해 `<=>`를 다시 계산합니다. LIMIT이 있으면 벡터 10개지만, LIMIT이 없는 I 형태에서는 조건에 맞는 벡터가
  모두(384차원이면 하나에 1.5 KB) Postgres로 옵니다. 같은 함수도 `WHERE` 안에서는 푸시다운됩니다(H).
- **연산자가 인덱스와 맞아야 합니다.** `<=>`는 `cosineDistance` 인덱스, `<->`는 `L2Distance` 인덱스가 필요합니다.
  `<#>`는 `dotProduct … DESC`로 정렬되며, `dotProduct` 인덱스가 쓰이는 형태입니다(ClickHouse 문서와 릴리스 노트
  기준, 여기서는 실행하지 않음). 애플리케이션이 보내는 연산자에 맞춰 ClickHouse 인덱스를 만드세요.
- **상한은 ClickHouse 설정입니다.** 26.9.7.9의 `max_limit_for_vector_search_queries`는 1000입니다(`system.settings`).
  pg_clickhouse는 이 값을 읽어 더 큰 LIMIT을 EXPLAIN에서 설명하지만 경고는 내지 않습니다. 실제로 돌리면
  `LIMIT 2000`은 오류 없이 정확 스캔으로 결과를 돌려줬고(HNSW 검색 없음, 254,158행, 189 ms), `LIMIT 1000`은
  인덱스를 썼지만 246,449행을 읽었습니다(120 ms).

#### 03 — `system.query_log`로 인덱스 사용 확인 ([03-index-in-query-log.sql](03-index-in-query-log.sql))

질의마다 `SET pg_clickhouse.session_settings = 'log_comment …'`로 태그를 붙입니다. 0.11.1부터 이 GUC는 기본
설정을 **키 단위로** 덮어쓰므로, 태그를 붙여도 `final 1`이나 `join_use_nulls 1`이 빠지지 않습니다(아래 모든 행의
`Settings['final']`이 `1`). 0.11.0에서는 같은 `SET`이 기본값을 통째로 바꿨습니다.
[pg-clickhouse-lab](../pg-clickhouse-lab/)의 06단계를 보세요. 로그는 Postgres에서 `clickhouse_query()`로 읽습니다.

| 태그(2026-11-20) | `USearchSearchCount` | 읽은 행 | ms |
|---|---|---|---|
| a: 코사인, LIMIT 10 | **1** | 30,583 | 44 |
| b: 코사인, `WHERE type = 1`(행의 4.6 %), LIMIT 10 | **1** | 30,583 | 41 |
| c: 코사인 인덱스에 L2 | 0 | 254,158 | 51 |
| d: 먼 순서 | 0 | 254,158 | 54 |
| e: `use_skip_indexes 0`으로 코사인 | 0 | 254,158 | 52 |

EXPLAIN의 예측이 모든 행에서 맞았습니다. 필터를 건 검색(b)은 10행을 돌려줬고, 필터를 건 상태의 recall은
재지 않았습니다.

#### 04 — recall과 지연 시간 ([04-recall-latency.sql](04-recall-latency.sql))

따로 떼어 둔 벡터 100개를 여섯 가지 방법으로 검색합니다. 방법마다 모든 질의를 두 번 돌리고 두 번째만 잽니다.
시간은 Postgres 백엔드에서 잰 벽시계 시간이므로 `ch_*` 행에는 ClickHouse 왕복이 포함됩니다. recall은
`hn_truth` 기준입니다.

| 방법(2026-11-20) | 방식 | recall@10 | p50 ms | p95 ms |
|---|---|---|---|---|
| `ch_index` | 외부 테이블, `ORDER BY emb <=> $1 LIMIT 10` | 0.996 | 46.39 | 59.14 |
| `ch_exact` | 같은 질의, `use_skip_indexes 0` | 1.000 | 54.07 | 59.19 |
| `ch_query_ids` | `clickhouse_query()`, 같은 검색에서 `id`만 선택 | 0.995 | **3.39** | 5.41 |
| `pg_hnsw_ef40` | 로컬 pgvector HNSW, `hnsw.ef_search = 40`(기본값) | 0.977 | 2.97 | 3.94 |
| `pg_hnsw_ef256` | 로컬 pgvector HNSW, `hnsw.ef_search = 256`(ClickHouse 검색 기본값) | 0.999 | 14.60 | 23.64 |
| `pg_exact` | 로컬, 인덱스 스캔 끔 | 1.000 | 29.56 | 32.41 |

ClickHouse 쪽(`system.query_log`, 같은 회차. 바이트 열은 검증 실행 뒤 스크립트에 더하고 04단계를 다시 돌려 확인했으며,
값은 검증 실행의 것을 Play UI에서 읽었습니다):

| 태그 | p50 ms | p95 ms | HNSW 검색 | 평균 읽은 행 | 평균 읽은 바이트 |
|---|---|---|---|---|---|
| `pgvec_04_ch_index` | 45 | 59 | 100 | 58,761 | 43.64 MiB |
| `pgvec_04_ch_query_ids` | **3** | 4 | 100 | 58,761 | 525.29 KiB |
| `pgvec_04_ch_exact` | 53 | 59 | 0 | 283,541 | 376.33 MiB |

**인덱스 검색은 빠르고, 벡터 컬럼을 가져오는 일이 느립니다.** `ch_index`와 `ch_query_ids`는 같은 HNSW 검색을
합니다(검색 100회, 읽은 행 수도 같음). 다른 것은 SELECT 목록뿐입니다. 계획의 `Output`이 돌아온 행에 대해
`emb <=> $1`을 Postgres에서 계산하므로(02단계 A 형태) pg_clickhouse는 `SELECT id, emb …`를 보내고, ClickHouse는
인덱스가 가리키는 그래뉼마다 `emb` 컬럼을 읽습니다. 질의 100개의 평균 `read_bytes`는 `ch_index` 43.64 MiB,
`ch_query_ids` 525.29 KiB였습니다(`system.query_log`, 같은 회차). ClickHouse에서 직접 돌리면 한 번 검색에
`id, emb`는 45.84 MiB, `id`만은 700.12 KiB를 읽었습니다(각각 세 번, 중앙값 54 ms 대 4 ms). 시간은 전송이 아니라
ClickHouse 안에서 씁니다. 두 방법 모두 Postgres 쪽 p50이 ClickHouse 쪽 p50과 1 ms 안팎으로 차이 납니다.

그래서 지연 시간이 중요한 경로라면 `id`만 고르는 질의를 `clickhouse_query()`로 보내고(`ch_query_ids`처럼)
나머지는 Postgres에서 조인하세요. 외부 테이블 형태는 평범한 SQL을 그대로 쓸 수 있고, 인덱스도 씁니다.

이 설정에서 ClickHouse 인덱스(`bf16`, `ef_search` 256)는 0.995–0.996, pgvector는 기본 `ef_search` 40에서 0.977,
256에서 0.999였습니다. 노트북 한 대에서 벡터 254,158개로 각각 한 가지 설정을 비교한 결과입니다. 백만 개
벡터를 같은 recall에서 비교한 결과는 [managed-postgres/vector-search](../../managed-postgres/vector-search/)에 있습니다.

### 📁 파일 구조

```text
pg-clickhouse-pgvector/
├── docker-compose.yml          # ClickHouse 26.9.7.9 + Postgres(빌드), 포트 15432 / 18123 / 19000
├── postgres/Dockerfile         # ghcr.io/clickhouse/pg_clickhouse:18-0.11.1 + postgresql-18-pgvector 0.8.7
├── 00-setup.sh
├── 01-load.sh                  # 내려받기(한 번), 이어서 아래 SQL 두 개
├── 01-load-clickhouse.sql      # 정리, 분할, HNSW 인덱스, 정답
├── 01-postgres-objects.sql     # 외부 서버와 테이블, 로컬 pgvector 사본 + HNSW
├── 02-pushdown-shapes.sh/.sql
├── 03-index-in-query-log.sh/.sql
├── 04-recall-latency.sh/.sql
├── psql.sh · clickhouse-client.sh · cleanup.sh
└── README.md
```

### 🔍 출처

- [pg_clickhouse v0.11.1 릴리스 노트](https://github.com/ClickHouse/pg_clickhouse/releases/tag/v0.11.1) (2026-11-20 확인)
- [ClickHouse 문서 — Exact and Approximate Vector Search](https://clickhouse.com/docs/engines/table-engines/mergetree-family/annindexes) (2026-11-20 확인). 문서와 26.9.7.9 빌드가 다른 곳은 `system.settings`를 따랐습니다. 빌드에서는 `max_limit_for_vector_search_queries` 1000, `vector_search_with_rescoring` 0입니다.
- [pgvector v0.8.7 README](https://github.com/pgvector/pgvector/blob/v0.8.7/README.md) (2026-11-20 확인)
- [ClickHouse 문서 — Hacker News 벡터 검색 데이터셋](https://clickhouse.com/docs/get-started/sample-datasets/hacker-news-vector-search)

---

## License

[MIT](../../LICENSE) — same as the rest of the repository.

## 라이선스

[MIT](../../LICENSE) — 저장소 전체와 동일합니다.
