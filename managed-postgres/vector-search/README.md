# Vector search — pgvector, VectorChord and ClickHouse

[English](#english) | [한국어](#한국어)

---

## English

> **Related notes** (Korean): [ClickHouse Vector Search (25.8)](https://clickhouse.litkhai.dev/articles/feature/clickhouse-vector-search-25-8/)

Managed Postgres lists **three** vector extensions. Only one of them can
actually be used, and finding that out is the first result this lab produced.

| Extension | Catalogue | On a real service | |
|---|---|---|---|
| `vector` | 0.8.6 | **0.8.6, installs and works** | pgvector — `hnsw`, `ivfflat` |
| `vchord` | 1.1.1 | ❌ **cannot be created** | VectorChord — needs `shared_preload_libraries` |
| `vchord_bm25` | 0.3.0 | ❌ same blocker | BM25 as an access method |

The catalogue was read on 2026-10-01 and the service checked on 2026-10-02. On
2026-08-23 the catalogue listed `vector` 0.8.2 and the service installed 0.8.5;
`vchord` failed the same way both times.

```text
postgres=> CREATE EXTENSION vchord;
ERROR:  vchord must be loaded via shared_preload_libraries.

postgres=> ALTER SYSTEM SET shared_preload_libraries = '…,vchord';
ERROR:  ALTER SYSTEM is not allowed in this environment
```

The service preloads `pg_cron, pg_stat_statements, pg_stat_ch` and nothing else,
and you cannot change it. **Being in the extension catalogue is not the same as
being usable** — worth knowing before you plan an architecture around it.

Alongside them, ClickHouse has had a `vector_similarity` index — HNSW backed
by usearch — since 24.8 ([#63675](https://github.com/ClickHouse/ClickHouse/pull/63675)), experimental at first and GA since
[25.8](https://clickhouse.com/docs/whats-new/changelog/2025#258). So the same million vectors can be indexed three ways
in Postgres and a fourth way in ClickHouse, and the question this lab answers
is not "which is fastest" but **where the line is**: at what size does vector
search stop belonging in Postgres, and does VectorChord move that line?

> **Status: run end to end against both real products, most recently on
> 2026-10-02** — ClickHouse Managed Postgres (PostgreSQL 18.6, pgvector 0.8.6)
> and ClickHouse Cloud 26.6.1. The first run was on 2026-08-23 (PostgreSQL 18.4,
> pgvector 0.8.5, ClickHouse Cloud 26.4.1), and the tables below give both. Every
> number that carries a unit was measured on those services, not on a laptop and
> not quoted from a vendor.

### Why not just read a pgvector tutorial

Because they all stop before the interesting part. A tutorial shows you
`CREATE INDEX … USING hnsw` and a query that returns rows. It does not tell you

- that the index is roughly the same size as the table, because HNSW keeps full-precision vectors in its graph
- that IVFFlat built on an empty table is silently worthless
- that VectorChord raises an error rather than choosing a default when nobody set `vchordrq.probes`
- what any of it costs at a recall you would actually ship

and it never compares against the engine sitting next door.

### The dataset

[dbpedia-entities-openai3-text-embedding-3-large-1536-1M](https://huggingface.co/datasets/Qdrant/dbpedia-entities-openai3-text-embedding-3-large-1536-1M)
— 1,000,000 Wikipedia articles with 1536-dimension embeddings from OpenAI's
`text-embedding-3-large`, published as 26 Parquet files.

**No API key, no embedding model, no download step.** ClickHouse reads the
Parquet directly over HTTPS with `url()`, and Postgres pulls from ClickHouse
through `pg_clickhouse`. The same ingestion route the
[bike lab](../postgis-fdw-bike/) uses, applied to a different problem.

| | |
|---|---|
| Rows | 38,462 per file × 26 = 1,000,000 |
| Dimensions | 1536, Float32 |
| Raw vector bytes | ~6.1 GB at full scale |
| Columns | `_id`, `title`, `text`, `text-embedding-3-large-1536-embedding` |

Start with one file. Everything downstream scales in proportion, and 38k rows
is enough to see every effect this lab is about.

### Run it

```bash
cp config.env.example config.env && $EDITOR config.env   # PG* for Postgres, CH_* for ClickHouse
```

**On ClickHouse:** run [`clickhouse/01-load-dbpedia.sql`](clickhouse/01-load-dbpedia.sql), either through the client or by pasting it into the SQL console.

```bash
./scripts/clickhouse.sh < clickhouse/01-load-dbpedia.sql
```

It creates `mpg_hols_vec.dbpedia`, loads it from Hugging Face and adds a `vector_similarity` index. The database has a dedicated name, so the lab can run on a shared ClickHouse service without touching anything else there.

**On Postgres:**

```bash
./scripts/psql.sh -f /sql/01-schema.sql
./scripts/psql.sh -f /sql/02-load-from-clickhouse.sql   # reads CH_* from config.env
./scripts/psql.sh -f /sql/03-ground-truth.sql           # exact answers + the harness

./scripts/psql.sh -f /sql/10-pgvector-hnsw.sql
./scripts/psql.sh -f /sql/11-pgvector-ivfflat.sql
./scripts/psql.sh -f /sql/12-vectorchord.sql
```

**Back on ClickHouse:** [`clickhouse/02-compare.sql`](clickhouse/02-compare.sql) measures the ClickHouse side by the same rule.

```bash
./scripts/clickhouse.sh < clickhouse/02-compare.sql
```

**Credentials.** Both scripts run their client in a container, and the password reaches it as an environment variable, never on a command line. `-v ch_host=…` and `-v ch_pass=…` still override `config.env` for `02-load`.

**On a shared ClickHouse service**, use a user that can only touch `mpg_hols_vec`. Run these as the service's `default` user. They are what the 2026-10-02 re-run granted on ClickHouse Cloud 26.6.1:

```sql
CREATE USER mpg_hols IDENTIFIED BY '…';
CREATE DATABASE IF NOT EXISTS mpg_hols_vec;
GRANT CURRENT GRANTS ON mpg_hols_vec.* TO mpg_hols;        -- GRANT ALL is not supported on Cloud
GRANT CREATE TEMPORARY TABLE ON *.* TO mpg_hols;
GRANT READ ON URL TO mpg_hols;                             -- url() for the Hugging Face Parquet
GRANT SELECT ON system.data_skipping_indices TO mpg_hols;  -- the index size in 02-compare
```

On a server without read/write source grants, the `URL` grant is written `GRANT URL ON *.* TO mpg_hols`.

No cloud account yet? `./scripts/local-postgres.sh up` starts a container with
pgvector and VectorChord, but not `pg_clickhouse`: its extension directory holds
`vector` and `vchord` only (checked 2026-10-10). So
`sql/02-load-from-clickhouse.sql`, the only load path in this lab, cannot run
against it, and `vec.dbpedia` has to be filled some other way before the index
files are worth running there.

### Measuring it honestly

**A vector benchmark that reports speed without recall is measuring nothing.**
Any index can be made arbitrarily fast by looking at fewer candidates. So the
harness in [`sql/03-ground-truth.sql`](sql/03-ground-truth.sql) does two things
before anything is compared:

1. Picks 20 query vectors from the corpus itself, ordered by `md5(id)` so the
   set is reproducible and identical on both engines.
2. Computes the **exact** top-10 for each by brute force, with parallelism off,
   and stores it. That table is the reference every approximate method is
   scored against.

`vec.recall_at_10()` then reports the fraction of the true top-10 that a method
actually returned, and `vec.sweep()` times the whole query set rather than one
cold lookup.

On the ClickHouse side the same care is needed in a different place: the ground
truth query sets `use_skip_indexes = 0`, because letting ClickHouse answer the
reference query with its own vector index guarantees a recall of 1.000 and
tells you nothing.

### What the numbers looked like

Measured on the **real products**, with one Parquet file loaded into both:
**38,462 rows × 1536 dimensions**. All figures are warm; see the last finding below.

There were two runs:

| Run | Postgres | ClickHouse |
|---|---|---|
| 2026-08-23 | PostgreSQL 18.4, pgvector 0.8.5 | ClickHouse Cloud 26.4.1 |
| 2026-10-02 | PostgreSQL 18.6, pgvector 0.8.6, on an `r6gd.large` | ClickHouse Cloud 26.6.1 |

The 2026-10-02 Postgres service was shared with two live demos: pg_cron jobs ran every minute and two CDC slots were active.

**Postgres** — each cell is *2026-08-23 / 2026-10-02*

| Method | Build | recall@10 | ms / query | Index size |
|---|---|---|---|---|
| exact, no index | — | 1.000 / 1.000 | **375.1** / 376.0 | — (table 322 MB / 322 MB) |
| `hnsw`, `ef_search=20` | 68.4 s / 67.0 s | 0.975 / 0.990 | **0.99** / 0.98 | 300 MB / 300 MB |
| `hnsw`, `ef_search=40` | " | 0.975 / 0.990 | 1.45 / 1.50 | " |
| `hnsw`, `ef_search=100` | " | 0.980 / 0.990 | 2.90 / 2.91 | " |
| `ivfflat`, `probes=1` | 11.4 s / 11.1 s | 0.700 / 0.740 | 1.05 / 1.12 | 301 MB / 301 MB |
| `ivfflat`, `probes=10` | " | 0.975 / 0.970 | 7.33 / 8.15 | " |
| `ivfflat`, `probes=30` | " | 0.995 / 0.990 | 21.44 / 22.08 | " |
| VectorChord | — | — | — | **unavailable** in both runs |

**ClickHouse**, same rows, `vector_similarity('hnsw','cosineDistance',1536,'bf16',16,64)`

| | 2026-08-23 (26.4.1) | 2026-10-02 (26.6.1) |
|---|---|---|
| Load from Hugging Face + index build | 44 s + 29 s | 53 s for all of `01-load` |
| Storage | 305.9 MiB on disk — 215.3 MiB data + **90.6 MiB index** | 305.87 MiB — 215.33 MiB data + **90.54 MiB index** |
| recall@10, `ef_search=64` | 0.985 | 0.985 |
| `EXPLAIN indexes=1` | granules 24 → 6 | granules 24 → 6 |
| Server-side latency | **~530 ms**, reading 25,880 of 38,462 rows | not re-measured |

Four things fall out, and none of them is the one people expect.

**At equal recall, HNSW beats IVFFlat by five times.** In the first run both reached 0.975: `ef_search=40` took 1.45 ms and `probes=10` took 7.33 ms. Pushing IVFFlat to 0.995 cost 21.44 ms, by which point the index had stopped earning its keep. HNSW paid for that with a build six times longer.

The re-run puts the two further apart. HNSW reached 0.990 at 0.98 ms, where IVFFlat needed `probes=30` and 22.08 ms.

**ClickHouse's vector index is not competitive at this size, and the plan says
why.** `EXPLAIN indexes=1` shows it working — granules pruned from 24 to 6 —
and on 2026-08-23 the query still read 25,880 of 38,462 rows and took ~530 ms server-side.
The default `GRANULARITY 100000000` means almost no index instances get built
for a small part, so pruning is coarse. Against 0.99 ms in Postgres that is not
a close call. **At 38k rows the vectors belong in Postgres**, and this lab's
question — where is the line — has its lower bound: well above here.

**Only the ClickHouse index compresses.** Postgres's indexes came out at
300–301 MB against a 322 MB table: HNSW and IVFFlat both keep full-precision
vectors. ClickHouse's `bf16` index is 90.6 MiB for the same data. Note also
that the embeddings themselves barely compress — 239.5 MiB down to 215.3 MiB,
about 10%, because uniformly distributed floats have nothing for a codec to
find. Whatever engine holds a billion of these will pay for them. (That
per-column figure is from 2026-08-23; ClickHouse Cloud 26.6.1 no longer reports
per-column sizes, see below.)

**The first measurement you take is wrong.** A rehearsal of this comparison on
a local container put HNSW at 5.6 ms, three times its warm number on the same
container (1.79 ms), because the
index had just been built and the page cache was empty. Every figure above is
from a warm run. A benchmark that does not say which is not telling you the
thing you need.

### Eight things that will bite you

**A correlated recall query stopped working after 26.4.** The first version of `02-compare.sql` scored all twenty queries in one statement. Each per-query `ORDER BY … LIMIT 10` referred to the outer `q.embedding`. It ran on 26.4.1, and later versions reject it:

- Local 26.5.7, 26.6.8 and 26.9.7: `Code: 48 … Correlated subqueries are not supported in JOINs yet`
- Cloud 26.6.1: `UNSUPPORTED_METHOD`, asking for `allow_experimental_correlated_subqueries`

The file now unrolls the twenty queries instead of enabling an experimental setting. Each one takes its reference vector as a constant scalar subquery, which the vector index still serves; `EXPLAIN` shows granules pruned from 24 to 6.

**ClickHouse Cloud does not report per-column sizes.** On 26.6.1, `system.columns` and `system.parts_columns` read `0.00 B` for every column. `system.tables.total_bytes` is populated, and it includes the vector index, so subtract the index before comparing it with a Postgres table size.

**Two settings cannot be sent as `SET` over the HTTPS interface.** ClickHouse
Cloud's HTTP endpoint rejects multi-statement bodies —
`Syntax error (Multi-statements are not allowed)` — so
`SET max_http_get_redirects=10; INSERT …` fails. Pass it as a query parameter
instead: `POST /?max_http_get_redirects=10`.

**`pg_clickhouse` hands you a Postgres array, and pgvector wants brackets.**
`Array(Float32)` arrives as `{-0.0018,0.0224,…}` and the cast fails with
*"Vector contents must start with `[`"*. There is no array-to-vector cast in
pgvector 0.8.x; `translate(embedding::text, '{}', '[]')::vector(1536)` is the
shortest bridge.

**Hugging Face redirects more than once.** ClickHouse allows one redirect by
default and fails with `Code: 483. Too many redirects`, followed by *"The table
structure cannot be extracted from a Parquet format file"* — which reads like a
corrupt file and is not. `SET max_http_get_redirects = 10`.

**Docker gives a container 64 MB of `/dev/shm`.** A parallel index build asks
for more and dies with `could not resize shared memory segment … No space left
on device`. Start the container with `--shm-size=2g`, or set
`max_parallel_maintenance_workers = 0`. On a managed service this never
happens; it only bites when you rehearse locally.

**IVFFlat must be built after the data is loaded.** It clusters what it can
see, so an index created on an empty table puts every later vector in one cell.
There is no error and no warning — just an index that does nothing until you
`REINDEX`.

**VectorChord has no default for `probes`.** Query through it in a session that
never set `vchordrq.probes` and you get `need 1 probes, but 0 probes provided`.
Better than silently guessing, but it means the setting belongs in your
application's connection setup, not in a `psql` session you ran once.

### Only one index at a time

The planner picks by cost and will not take instructions. Each of the three
`sql/1*.sql` files therefore drops the other two before building its own.

Toggling `pg_index.indisvalid` to hide an index looks like a shortcut and is a
trap: plan caching inside PL/pgSQL keeps handing back the old plan, and you get
three "different" methods that all report the sequential-scan number. The first
draft of this lab did exactly that and produced a table of identical results —
which is the failure mode worth recognising, because it looks like data.

### What has actually been run

| | |
|---|---|
| ✅ Verified on the real products | Run on 2026-08-23 and again on 2026-10-02: `vchord` cannot be created; loading Hugging Face Parquet into ClickHouse Cloud with `url()`; the `vector_similarity` index and its plan; pulling into Managed Postgres through `pg_clickhouse`; pgvector `hnsw` and `ivfflat` builds, sizes, recall and latency; ClickHouse recall at `ef_search=64`; every number in the tables above except those marked otherwise. `ALTER SYSTEM` being refused was checked on 2026-08-23 only |
| ❌ Blocked, not skipped | **VectorChord.** `sql/12-vectorchord.sql` is kept because the blocker may be lifted — the extension is packaged, it is only missing from `shared_preload_libraries`. Without it, the file currently keeps going and prints exact-scan rows labelled as VectorChord ([#13](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/13)) |
| ❌ Not yet run | The full million rows. One Parquet file of 26 was used |
| ❌ Not yet written | The `vchord_bm25` hybrid-search stage, which the same blocker prevents anyway |

The load path was measured too, and it is the reason
[`sql/02-load-from-clickhouse.sql`](sql/02-load-from-clickhouse.sql) goes
through the FDW. ClickHouse read the Parquet from Hugging Face in **44 s**, and
`pg_clickhouse` moved all 38,462 rows into Postgres in **38.9 s** (39.2 s on
the 2026-10-02 re-run). The
alternative — piping Parquet through a text pipeline into `COPY` — managed
roughly **3,000 rows a minute** in rehearsal, because every float becomes a
decimal string. Same data, thirteen minutes instead of thirty-nine seconds.

### Where this goes next

- **The full million.** Everything here is method; the interesting numbers are at 1M rows where a 6 GB working set stops fitting comfortably.
- **`vchord_bm25`.** The dataset carries the article text, so lexical + vector hybrid search is one index away — and it has a counterpart to be measured against in [`usecase/fulltext-search`](https://github.com/litkhai/clickhouse-hols/tree/main/usecase/fulltext-search).
- **Where the vectors should live.** If the embeddings only ever get searched and never updated, the argument that moved aggregation to ClickHouse in the [bike lab](../postgis-fdw-bike/) applies here too. That is the question worth ending on.

### Further reading

[WRITEUP.md](WRITEUP.md) — how the comparison was built, in the order it
happened, with the wrong turns left in: why the premise changed before any
measurement, the two format traps in the ingestion path, how a cold cache and
a clever index-hiding trick each produced numbers that looked like data, and
what a laptop could not have told us. Written as source material for a longer
article.

### 📄 License

[MIT](../../LICENSE) — same as the rest of the repository. The dbpedia
embeddings are fetched at run time from Hugging Face under their own terms and
are not redistributed here.

---

## 한국어

> **관련 글**: [ClickHouse Vector Search (25.8)](https://clickhouse.litkhai.dev/articles/feature/clickhouse-vector-search-25-8/)

Managed Postgres 카탈로그에는 벡터 확장이 **셋** 올라와 있습니다. 그중 실제로
쓸 수 있는 것은 하나뿐이고, 그 사실을 알아낸 것이 이 랩의 첫 번째 결과입니다.

| 확장 | 카탈로그 | 실제 서비스 | |
|---|---|---|---|
| `vector` | 0.8.6 | **0.8.6, 설치·동작** | pgvector — `hnsw`, `ivfflat` |
| `vchord` | 1.1.1 | ❌ **생성 불가** | VectorChord — `shared_preload_libraries` 필요 |
| `vchord_bm25` | 0.3.0 | ❌ 같은 이유 | BM25를 접근 방법으로 |

카탈로그는 2026-10-01에, 서비스는 2026-10-02에 확인했습니다. 2026-08-23에는
카탈로그에 `vector` 0.8.2가 올라 있었고 서비스에는 0.8.5가 설치됐습니다. `vchord`는
두 번 모두 같은 이유로 실패했습니다.

```text
postgres=> CREATE EXTENSION vchord;
ERROR:  vchord must be loaded via shared_preload_libraries.

postgres=> ALTER SYSTEM SET shared_preload_libraries = '…,vchord';
ERROR:  ALTER SYSTEM is not allowed in this environment
```

서비스가 미리 로드하는 것은 `pg_cron, pg_stat_statements, pg_stat_ch`뿐이고
사용자가 바꿀 수 없습니다. **확장 카탈로그에 있다는 것과 쓸 수 있다는 것은 다른
얘기입니다** — 그것을 전제로 아키텍처를 짜기 전에 알아둘 만합니다.

그 옆에서 ClickHouse는 24.8([#63675](https://github.com/ClickHouse/ClickHouse/pull/63675))부터 usearch 기반 HNSW인
`vector_similarity` 인덱스를 갖고 있습니다. 처음엔 실험 기능이었고
[25.8](https://clickhouse.com/docs/whats-new/changelog/2025#258)에서 GA가 됐습니다. 같은 100만 벡터를 Postgres에서 세 가지로, ClickHouse에서
네 번째 방식으로 색인할 수 있다는 뜻이고, 이 랩이 답하는 질문은 "무엇이 제일
빠른가"가 아니라 **선이 어디인가**입니다 — 벡터 검색은 어느 규모부터 Postgres의
일이 아니게 되며, VectorChord는 그 선을 옮기는가.

> **상태: 두 실제 제품에서 끝까지 실행했고, 가장 최근은 2026-10-02입니다** —
> ClickHouse Managed Postgres(PostgreSQL 18.6, pgvector 0.8.6)와 ClickHouse
> Cloud 26.6.1. 처음 실행은 2026-08-23(PostgreSQL 18.4, pgvector 0.8.5,
> ClickHouse Cloud 26.4.1)이었고, 아래 표에 두 번 모두 실었습니다. 단위가 붙은
> 수치는 전부 그 서비스들에서 측정한 것이며, 노트북 수치도 벤더 인용도 아닙니다.

### pgvector 튜토리얼로 충분하지 않은 이유

전부 흥미로워지기 직전에 끝나기 때문입니다. 튜토리얼은
`CREATE INDEX … USING hnsw`와 행이 나오는 쿼리를 보여줄 뿐,

- HNSW가 그래프에 전체 정밀도 벡터를 담기 때문에 **인덱스가 테이블만 하다**는 것
- 빈 테이블에 만든 IVFFlat은 **조용히 무용지물**이라는 것
- 아무도 `vchordrq.probes`를 설정하지 않으면 VectorChord는 기본값을 고르는 대신 **오류를 낸다**는 것
- 실제로 서비스할 만한 recall에서 그것들이 각각 얼마를 청구하는지

는 말해주지 않습니다. 그리고 바로 옆에 있는 엔진과 비교하는 법이 없습니다.

### 데이터

[dbpedia-entities-openai3-text-embedding-3-large-1536-1M](https://huggingface.co/datasets/Qdrant/dbpedia-entities-openai3-text-embedding-3-large-1536-1M)
— 위키백과 문서 100만 건과 OpenAI `text-embedding-3-large`의 1536차원 임베딩,
Parquet 26개 파일.

**API 키도, 임베딩 모델도, 다운로드 단계도 없습니다.** ClickHouse가 `url()`로
Parquet을 HTTPS에서 바로 읽고, Postgres는 `pg_clickhouse`로 ClickHouse에서
끌어옵니다. [자전거 랩](../postgis-fdw-bike/)이 쓰는 적재 경로를 다른 문제에
그대로 적용한 것입니다.

| | |
|---|---|
| 행 수 | 파일당 38,462 × 26 = 1,000,000 |
| 차원 | 1536, Float32 |
| 원본 벡터 크기 | 전체 규모에서 약 6.1 GB |
| 컬럼 | `_id`, `title`, `text`, `text-embedding-3-large-1536-embedding` |

파일 하나로 시작하세요. 이후 모든 단계가 비례해서 무거워지고, 이 랩이 보여주려는
효과는 38,000행이면 전부 관찰됩니다.

### 실행

```bash
cp config.env.example config.env && $EDITOR config.env   # Postgres는 PG*, ClickHouse는 CH_*
```

**ClickHouse에서:** [`clickhouse/01-load-dbpedia.sql`](clickhouse/01-load-dbpedia.sql)을 실행합니다. 클라이언트로 돌려도 되고, SQL 콘솔에 붙여 넣어도 됩니다.

```bash
./scripts/clickhouse.sh < clickhouse/01-load-dbpedia.sql
```

`mpg_hols_vec.dbpedia`를 만들고 Hugging Face에서 적재한 뒤 `vector_similarity` 인덱스를 추가합니다. 데이터베이스 이름을 전용으로 정해 두었기 때문에, 공용 ClickHouse 서비스에서도 다른 것을 건드리지 않고 돌릴 수 있습니다.

**Postgres에서:**

```bash
./scripts/psql.sh -f /sql/01-schema.sql
./scripts/psql.sh -f /sql/02-load-from-clickhouse.sql   # config.env의 CH_*를 읽음
./scripts/psql.sh -f /sql/03-ground-truth.sql           # 정답셋 + 측정 하네스

./scripts/psql.sh -f /sql/10-pgvector-hnsw.sql
./scripts/psql.sh -f /sql/11-pgvector-ivfflat.sql
./scripts/psql.sh -f /sql/12-vectorchord.sql
```

**다시 ClickHouse에서:** [`clickhouse/02-compare.sql`](clickhouse/02-compare.sql)이 ClickHouse 쪽을 같은 기준으로 측정합니다.

```bash
./scripts/clickhouse.sh < clickhouse/02-compare.sql
```

**자격 증명.** 두 스크립트 모두 클라이언트를 컨테이너에서 실행하고, 비밀번호는 명령행이 아니라 환경 변수로 넘깁니다. `02-load`에서는 `-v ch_host=…`, `-v ch_pass=…`로 `config.env` 값을 덮어쓸 수 있습니다.

**공용 ClickHouse 서비스에서는** `mpg_hols_vec`만 다룰 수 있는 사용자를 쓰세요. 아래는 서비스의 `default` 사용자로 실행합니다. 2026-10-02 재실행 때 ClickHouse Cloud 26.6.1에서 실제로 부여한 권한입니다.

```sql
CREATE USER mpg_hols IDENTIFIED BY '…';
CREATE DATABASE IF NOT EXISTS mpg_hols_vec;
GRANT CURRENT GRANTS ON mpg_hols_vec.* TO mpg_hols;        -- Cloud에서는 GRANT ALL을 지원하지 않음
GRANT CREATE TEMPORARY TABLE ON *.* TO mpg_hols;
GRANT READ ON URL TO mpg_hols;                             -- Hugging Face Parquet을 읽는 url()
GRANT SELECT ON system.data_skipping_indices TO mpg_hols;  -- 02-compare의 인덱스 크기
```

read/write source grant가 꺼진 서버에서는 `URL` 권한을 `GRANT URL ON *.* TO mpg_hols`로 씁니다.

계정이 아직 없다면 `./scripts/local-postgres.sh up`이 pgvector와 VectorChord가
든 컨테이너를 띄웁니다. `pg_clickhouse`는 없습니다. 확장 디렉터리에 `vector`와
`vchord`만 있습니다(2026-10-10 확인). 그래서 이 랩의 유일한 적재 경로인
`sql/02-load-from-clickhouse.sql`은 거기서 돌지 않고, 인덱스 파일을 돌리기 전에
`vec.dbpedia`를 다른 방법으로 채워야 합니다.

### 정직하게 측정하기

**recall 없이 속도만 보고하는 벡터 벤치마크는 아무것도 측정하지 않은 것입니다.**
후보를 덜 보게 하면 어떤 인덱스든 원하는 만큼 빨라집니다. 그래서
[`sql/03-ground-truth.sql`](sql/03-ground-truth.sql)의 하네스는 비교 이전에 두
가지를 합니다.

1. 코퍼스 자체에서 쿼리 벡터 20개를 `md5(id)` 순으로 뽑습니다. 재현 가능하고 두
   엔진에서 동일한 집합이 됩니다.
2. 각각의 **정확한** top-10을 병렬을 끈 완전탐색으로 구해 저장합니다. 이 표가
   모든 근사 방법의 채점 기준입니다.

`vec.recall_at_10()`이 실제 top-10 중 몇 개를 되찾았는지 보고하고,
`vec.sweep()`은 한 번의 차가운 조회가 아니라 쿼리 세트 전체 시간을 잽니다.

ClickHouse 쪽은 같은 주의가 다른 지점에서 필요합니다. 정답셋 쿼리에
`use_skip_indexes = 0`을 거는데, 기준 쿼리를 ClickHouse 자신의 벡터 인덱스로
답하게 두면 recall이 반드시 1.000이 나오고 아무것도 알 수 없기 때문입니다.

### 실측 결과

**실제 제품에서** 측정했습니다. Parquet 파일 하나 — **38,462행 × 1536차원** — 를 양쪽에 적재했습니다. 모두 워밍 후 수치입니다(아래 마지막 항목 참조).

두 번 실행했습니다.

| 실행 | Postgres | ClickHouse |
|---|---|---|
| 2026-08-23 | PostgreSQL 18.4, pgvector 0.8.5 | ClickHouse Cloud 26.4.1 |
| 2026-10-02 | PostgreSQL 18.6, pgvector 0.8.6, `r6gd.large` | ClickHouse Cloud 26.6.1 |

2026-10-02의 Postgres 서비스는 라이브 데모 두 개와 같이 쓰는 서비스였습니다. pg_cron 작업이 1분마다 돌았고 CDC 슬롯 두 개가 활성 상태였습니다.

**Postgres** — 각 칸은 *2026-08-23 / 2026-10-02*

| 방법 | 빌드 | recall@10 | ms / 쿼리 | 인덱스 크기 |
|---|---|---|---|---|
| 완전탐색, 인덱스 없음 | — | 1.000 / 1.000 | **375.1** / 376.0 | — (테이블 322 MB / 322 MB) |
| `hnsw`, `ef_search=20` | 68.4초 / 67.0초 | 0.975 / 0.990 | **0.99** / 0.98 | 300 MB / 300 MB |
| `hnsw`, `ef_search=40` | 〃 | 0.975 / 0.990 | 1.45 / 1.50 | 〃 |
| `hnsw`, `ef_search=100` | 〃 | 0.980 / 0.990 | 2.90 / 2.91 | 〃 |
| `ivfflat`, `probes=1` | 11.4초 / 11.1초 | 0.700 / 0.740 | 1.05 / 1.12 | 301 MB / 301 MB |
| `ivfflat`, `probes=10` | 〃 | 0.975 / 0.970 | 7.33 / 8.15 | 〃 |
| `ivfflat`, `probes=30` | 〃 | 0.995 / 0.990 | 21.44 / 22.08 | 〃 |
| VectorChord | — | — | — | 두 번 모두 **사용 불가** |

**ClickHouse**, 같은 행, `vector_similarity('hnsw','cosineDistance',1536,'bf16',16,64)`

| | 2026-08-23 (26.4.1) | 2026-10-02 (26.6.1) |
|---|---|---|
| Hugging Face 적재 + 인덱스 빌드 | 44초 + 29초 | `01-load` 전체 53초 |
| 저장 | 디스크 305.9 MiB — 데이터 215.3 MiB + **인덱스 90.6 MiB** | 305.87 MiB — 데이터 215.33 MiB + **인덱스 90.54 MiB** |
| recall@10, `ef_search=64` | 0.985 | 0.985 |
| `EXPLAIN indexes=1` | granule 24 → 6 | granule 24 → 6 |
| 서버 측 지연 | **약 530 ms**, 38,462행 중 25,880행을 읽음 | 재측정 안 함 |

네 가지가 나오는데, 넷 다 흔히 예상하는 것과 다릅니다.

**같은 recall에서 HNSW가 IVFFlat보다 5배 빠릅니다.** 첫 실행에서 둘 다 0.975에 도달했는데, `ef_search=40`이 1.45ms, `probes=10`이 7.33ms였습니다. IVFFlat을 0.995까지 밀면 21.44ms가 들었고, 그쯤이면 인덱스가 제 값을 못 합니다. HNSW는 그 대가로 6배 긴 빌드 시간을 냈습니다.

재실행에서는 차이가 더 벌어졌습니다. HNSW는 0.98ms에 0.990에 도달했고, IVFFlat은 같은 recall에 `probes=30`과 22.08ms가 필요했습니다.

**ClickHouse 벡터 인덱스는 이 규모에서 경쟁이 안 되고, 실행 계획이 이유를
말해줍니다.** `EXPLAIN indexes=1`을 보면 인덱스는 동작합니다 — granule을 24개에서
6개로 프루닝합니다. 그런데도 2026-08-23에는 38,462행 중 25,880행을 읽고 서버 측
약 530ms가 걸렸습니다. 기본값 `GRANULARITY 100000000` 때문에 작은 파트에는 인덱스 인스턴스가
거의 만들어지지 않아 프루닝이 거칩니다. Postgres의 0.99ms와 견줄 상황이
아닙니다. **38,000행에서 벡터는 Postgres에 있어야 하고**, "선이 어디인가"라는 이
랩의 질문은 하한을 얻었습니다 — 여기보다 한참 위입니다.

**압축하는 것은 ClickHouse 인덱스뿐입니다.** Postgres 인덱스는 322 MB 테이블에
300~301 MB로 나왔습니다. HNSW도 IVFFlat도 전체 정밀도 벡터를 그대로 갖습니다.
ClickHouse의 `bf16` 인덱스는 같은 데이터에 90.6 MiB입니다. 그리고 임베딩 자체는
거의 압축되지 않습니다 — 239.5 MiB에서 215.3 MiB, 약 10%입니다. 고르게 분포한
실수에는 코덱이 찾아낼 규칙이 없기 때문입니다. 10억 개를 담는 엔진이 어디든 그
값은 치러야 합니다. (컬럼별 수치는 2026-08-23 것입니다. ClickHouse Cloud 26.6.1은
컬럼별 크기를 더 이상 보고하지 않습니다 — 아래 참조.)

**첫 측정은 틀립니다.** 로컬 컨테이너 예행연습에서 HNSW가 5.6ms로 나왔는데,
같은 컨테이너의 워밍 후 수치(1.79ms)의 3배였습니다. 인덱스를 갓 만들어 페이지 캐시가 비어 있었기
때문입니다. 위 수치는 전부 워밍 후입니다. 어느 쪽인지 밝히지 않는 벤치마크는
필요한 것을 말해주지 않는 벤치마크입니다.

### 물릴 만한 것 여덟 가지

**상관 서브쿼리로 쓴 recall 쿼리가 26.4 이후 동작하지 않습니다.** 처음 `02-compare.sql`은 질의 스무 개를 한 문장으로 채점했습니다. 질의마다 `ORDER BY … LIMIT 10` 안에서 바깥의 `q.embedding`을 참조하는 형태였습니다. 26.4.1에서는 돌았지만 이후 버전은 거부합니다.

- 로컬 26.5.7, 26.6.8, 26.9.7: `Code: 48 … Correlated subqueries are not supported in JOINs yet`
- Cloud 26.6.1: `UNSUPPORTED_METHOD`. `allow_experimental_correlated_subqueries`를 켜라고 합니다.

실험 설정을 켜는 대신, 지금 파일은 질의 스무 개를 하나씩 펼쳐 씁니다. 각 질의는 기준 벡터를 상수 스칼라 서브쿼리로 받고, 벡터 인덱스는 그대로 쓰입니다. `EXPLAIN`에서 granule이 24개에서 6개로 줄어듭니다.

**ClickHouse Cloud는 컬럼별 크기를 보고하지 않습니다.** 26.6.1에서는 `system.columns`와 `system.parts_columns` 모두 모든 컬럼을 `0.00 B`로 보여 줍니다. `system.tables.total_bytes`는 값이 채워져 있는데, 벡터 인덱스가 포함된 값입니다. Postgres 테이블 크기와 비교하기 전에 인덱스를 빼세요.

**HTTPS 인터페이스로는 `SET`을 함께 보낼 수 없습니다.** ClickHouse Cloud의 HTTP
엔드포인트는 다중 문장 본문을 거부합니다 —
`Syntax error (Multi-statements are not allowed)`. 즉
`SET max_http_get_redirects=10; INSERT …`는 실패합니다. 쿼리 파라미터로
넘기세요: `POST /?max_http_get_redirects=10`.

**`pg_clickhouse`는 Postgres 배열을 주고 pgvector는 대괄호를 원합니다.**
`Array(Float32)`가 `{-0.0018,0.0224,…}`로 도착해 캐스팅이
*"Vector contents must start with `[`"*로 실패합니다. pgvector 0.8.x에는
배열→vector 캐스팅이 없고, `translate(embedding::text, '{}', '[]')::vector(1536)`이
가장 짧은 다리입니다.

**Hugging Face는 리다이렉트를 한 번 이상 합니다.** ClickHouse 기본값은 1회라
`Code: 483. Too many redirects`로 실패하고, 뒤이어 *"The table structure cannot
be extracted from a Parquet format file"*이 붙습니다 — 깨진 파일처럼 보이지만
아닙니다. `SET max_http_get_redirects = 10`.

**Docker는 컨테이너에 `/dev/shm` 64 MB만 줍니다.** 병렬 인덱스 빌드가 그보다
크게 요구하면 `could not resize shared memory segment … No space left on
device`로 죽습니다. `--shm-size=2g`로 띄우거나
`max_parallel_maintenance_workers = 0`을 설정하세요. 관리형 서비스에서는 생기지
않고, 로컬에서 예행연습할 때만 물립니다.

**IVFFlat은 데이터를 적재한 뒤에 만들어야 합니다.** 보이는 것을 클러스터링하므로
빈 테이블에 만들면 이후 들어온 벡터가 전부 한 셀에 들어갑니다. 오류도 경고도
없고, `REINDEX` 전까지 아무 일도 하지 않는 인덱스가 남을 뿐입니다.

**VectorChord의 `probes`에는 기본값이 없습니다.** `vchordrq.probes`를 설정한 적
없는 세션에서 이 인덱스로 조회하면 `need 1 probes, but 0 probes provided`가
납니다. 조용히 추측하는 것보다는 낫지만, 그 설정이 한 번 실행한 `psql` 세션이
아니라 애플리케이션 접속 초기화에 들어가야 한다는 뜻입니다.

### 인덱스는 한 번에 하나만

플래너는 비용으로 고르고 지시를 받지 않습니다. 그래서 `sql/1*.sql` 세 파일은
각자 자기 인덱스를 만들기 전에 나머지 둘을 삭제합니다.

`pg_index.indisvalid`를 꺼서 인덱스를 숨기는 방법은 지름길처럼 보이지만 함정
입니다. PL/pgSQL 내부의 계획 캐싱이 옛 계획을 계속 돌려주고, 결국 "서로 다른"
세 방법이 모두 순차 스캔 수치를 보고합니다. 이 랩의 초안이 정확히 그렇게 해서
전부 동일한 결과표를 만들어냈습니다 — 데이터처럼 보이기 때문에 더 알아둘 만한
실패 양상입니다.

### 실제로 돌려본 것

| | |
|---|---|
| ✅ 실제 제품에서 검증 | 2026-08-23에 실행하고 2026-10-02에 다시 실행: `vchord` 생성 불가, `url()`로 ClickHouse Cloud에 HF Parquet 적재, `vector_similarity` 인덱스와 실행 계획, `pg_clickhouse`로 Managed Postgres에 끌어오기, pgvector `hnsw`·`ivfflat`의 빌드·크기·recall·지연, `ef_search=64`에서의 ClickHouse recall, 위 표에서 따로 표시한 것을 뺀 모든 수치. `ALTER SYSTEM` 거부는 2026-08-23에만 확인 |
| ❌ 막힘 (건너뛴 것이 아님) | **VectorChord.** 패키지는 있고 `shared_preload_libraries`에만 빠져 있어 나중에 풀릴 수 있으므로 `sql/12-vectorchord.sql`은 남겨둡니다. 확장이 없으면 지금 이 파일은 멈추지 않고 VectorChord라는 이름으로 완전탐색 결과를 찍습니다 ([#13](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/13)) |
| ❌ 미실행 | 100만 행 전체. 26개 중 Parquet 1개만 사용 |
| ❌ 미작성 | `vchord_bm25` 하이브리드 단계 — 어차피 같은 이유로 막혀 있음 |

적재 경로도 측정했고, 그것이
[`sql/02-load-from-clickhouse.sql`](sql/02-load-from-clickhouse.sql)이 FDW를
쓰는 이유입니다. ClickHouse가 Hugging Face에서 **44초**에 읽었고,
`pg_clickhouse`가 38,462행 전부를 Postgres로 **38.9초**에 옮겼습니다(2026-10-02
재실행에서는 39.2초). 대안인
Parquet→텍스트 파이프라인→`COPY`는 예행연습에서 **분당 약 3,000행**이었습니다 —
모든 float이 십진 문자열이 되기 때문입니다. 같은 데이터로 39초 대신 13분입니다.

### 다음

- **100만 행 전체.** 여기 있는 것은 방법론이고, 흥미로운 수치는 6 GB 작업집합이 편하게 들어가지 않게 되는 100만 행에서 나옵니다.
- **`vchord_bm25`.** 데이터에 본문 텍스트가 함께 있어서 어휘+벡터 하이브리드 검색이 인덱스 하나 거리이고, [`usecase/fulltext-search`](https://github.com/litkhai/clickhouse-hols/tree/main/usecase/fulltext-search)라는 비교 대상도 이미 있습니다.
- **벡터가 어디에 있어야 하는가.** 임베딩이 검색만 되고 갱신되지 않는다면, [자전거 랩](../postgis-fdw-bike/)에서 집계를 ClickHouse로 옮긴 논리가 여기에도 적용됩니다. 마지막에 던질 만한 질문입니다.

### 더 읽을거리

[WRITEUP.md](WRITEUP.md) — 이 비교를 만든 과정을 일어난 순서대로, 잘못 든 길을
남긴 채 정리했습니다. 측정 전에 전제가 바뀐 이유, 적재 경로의 형식 함정 둘, 차가운
캐시와 영리한 인덱스 숨기기가 각각 어떻게 데이터처럼 보이는 수치를 만들어냈는지,
그리고 노트북으로는 알 수 없었던 것. 긴 글의 소재로 쓸 수 있게 정리했습니다.

### 📄 라이선스

[MIT](../../LICENSE) — 저장소 전체와 동일합니다. dbpedia 임베딩은 실행 시점에
Hugging Face에서 각자의 약관으로 받아오며 여기 재배포하지 않습니다.
