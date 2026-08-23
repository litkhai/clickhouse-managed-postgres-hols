# Vector search — pgvector, VectorChord and ClickHouse

[English](#english) | [한국어](#한국어)

---

## English

Managed Postgres lists **three** vector extensions. Only one of them can
actually be used, and finding that out is the first result this lab produced.

| Extension | Catalogue | On a real service | |
|---|---|---|---|
| `vector` | 0.8.2 | **0.8.5, installs and works** | pgvector — `hnsw`, `ivfflat` |
| `vchord` | 1.1.1 | ❌ **cannot be created** | VectorChord — needs `shared_preload_libraries` |
| `vchord_bm25` | 0.3.0 | ❌ same blocker | BM25 as an access method |

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
by usearch — since 26.4. So the same million vectors can be indexed three ways
in Postgres and a fourth way in ClickHouse, and the question this lab answers
is not "which is fastest" but **where the line is**: at what size does vector
search stop belonging in Postgres, and does VectorChord move that line?

> **Status: run end to end against both real products on 2026-08-23.**
> ClickHouse Managed Postgres (PostgreSQL 18.4, pgvector 0.8.5) and ClickHouse
> Cloud 26.4.1. Every number below that carries a unit was measured there, not
> on a laptop and not quoted from a vendor.

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
cp config.env.example config.env && $EDITOR config.env
```

**On ClickHouse** — paste [`clickhouse/01-load-dbpedia.sql`](clickhouse/01-load-dbpedia.sql)
into the SQL console. It creates `vec.dbpedia`, loads it from Hugging Face, and
adds a `vector_similarity` index.

**On Postgres:**

```bash
./scripts/psql.sh -f /sql/01-schema.sql
./scripts/psql.sh -v ch_host=… -v ch_pass=… -f /sql/02-load-from-clickhouse.sql
./scripts/psql.sh -f /sql/03-ground-truth.sql     # exact answers + the harness

./scripts/psql.sh -f /sql/10-pgvector-hnsw.sql
./scripts/psql.sh -f /sql/11-pgvector-ivfflat.sql
./scripts/psql.sh -f /sql/12-vectorchord.sql
```

Then [`clickhouse/02-compare.sql`](clickhouse/02-compare.sql) measures the
ClickHouse side by the same rule.

No cloud account yet? `./scripts/local-postgres.sh up` starts a container with
both extensions, and everything except the ClickHouse comparison works against
it.

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

Measured on the **real products**: ClickHouse Managed Postgres (PostgreSQL
18.4, pgvector 0.8.5) and ClickHouse Cloud 26.4.1, one Parquet file —
**38,462 rows × 1536 dimensions** — loaded into both. Warm; see the last
finding below.

**Postgres**

| Method | Build | recall@10 | ms / query | Index size |
|---|---|---|---|---|
| exact, no index | — | 1.000 | **375.1** | — (table 322 MB) |
| `hnsw`, `ef_search=20` | 68.4 s | 0.975 | **0.99** | 300 MB |
| `hnsw`, `ef_search=40` | " | 0.975 | 1.45 | 300 MB |
| `hnsw`, `ef_search=100` | " | 0.980 | 2.90 | 300 MB |
| `ivfflat`, `probes=1` | 11.4 s | 0.700 | 1.05 | 301 MB |
| `ivfflat`, `probes=10` | " | 0.975 | 7.33 | 301 MB |
| `ivfflat`, `probes=30` | " | 0.995 | 21.44 | 301 MB |
| VectorChord | — | — | — | **unavailable** |

**ClickHouse**, same rows, `vector_similarity('hnsw','cosineDistance',1536,'bf16',16,64)`

| | |
|---|---|
| Load from Hugging Face | 44 s |
| Index build | 29 s |
| Storage | 305.9 MiB on disk — 215.3 MiB data + **90.6 MiB index** |
| recall@10 | 0.985 |
| Server-side latency | **~530 ms**, reading 25,880 of 38,462 rows |

Four things fall out, and none of them is the one people expect.

**At equal recall, HNSW beats IVFFlat by five times.** Both reach 0.975 —
`ef_search=40` at 1.45 ms against `probes=10` at 7.33 ms. Push IVFFlat to 0.995
and it costs 21.44 ms, by which point the index has stopped earning its keep.
HNSW paid for that with a build six times longer.

**ClickHouse's vector index is not competitive at this size, and the plan says
why.** `EXPLAIN indexes=1` shows it working — granules pruned from 24 to 6 —
and the query still reads 25,880 of 38,462 rows and takes ~530 ms server-side.
The default `GRANULARITY 100000000` means almost no index instances get built
for a small part, so pruning is coarse. Against 0.99 ms in Postgres that is not
a close call. **At 38k rows the vectors belong in Postgres**, and this lab's
question — where is the line — has its lower bound: well above here.

**Only the ClickHouse index compresses.** Postgres's indexes came out at
300–301 MB against a 322 MB table: HNSW and IVFFlat both keep full-precision
vectors. ClickHouse's `bf16` index is 90.6 MiB for the same data. Note also
that the embeddings themselves barely compress — 239.5 MiB down to 215.3 MiB,
about 10%, because uniformly distributed floats have nothing for a codec to
find. Whatever engine holds a billion of these will pay for them.

**The first measurement you take is wrong.** A rehearsal of this comparison on
a local container put HNSW at 5.6 ms, three times its warm number, because the
index had just been built and the page cache was empty. Every figure above is
from a warm run. A benchmark that does not say which is not telling you the
thing you need.

### Six things that will bite you

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
| ✅ Verified on the real products | `vchord` cannot be created and `ALTER SYSTEM` is refused; loading Hugging Face Parquet into ClickHouse Cloud with `url()`; the `vector_similarity` index and its plan; pulling into Managed Postgres through `pg_clickhouse`; pgvector `hnsw` and `ivfflat` builds, sizes, recall and latency; every number in the tables above |
| ❌ Blocked, not skipped | **VectorChord.** `sql/12-vectorchord.sql` is kept because the blocker may be lifted — the extension is packaged, it is only missing from `shared_preload_libraries` |
| ❌ Not yet run | The full million rows. One Parquet file of 26 was used |
| ❌ Not yet written | The `vchord_bm25` hybrid-search stage, which the same blocker prevents anyway |

The load path was measured too, and it is the reason
[`sql/02-load-from-clickhouse.sql`](sql/02-load-from-clickhouse.sql) goes
through the FDW. ClickHouse read the Parquet from Hugging Face in **44 s**, and
`pg_clickhouse` moved all 38,462 rows into Postgres in **38.9 s**. The
alternative — piping Parquet through a text pipeline into `COPY` — managed
roughly **3,000 rows a minute** in rehearsal, because every float becomes a
decimal string. Same data, thirteen minutes instead of thirty-nine seconds.

### Where this goes next

- **The full million.** Everything here is method; the interesting numbers are at 1M rows where a 6 GB working set stops fitting comfortably.
- **`vchord_bm25`.** The dataset carries the article text, so lexical + vector hybrid search is one index away — and it has a counterpart to be measured against in [`usecase/fulltext-search`](../../usecase/fulltext-search/).
- **Where the vectors should live.** If the embeddings only ever get searched and never updated, the argument that moved aggregation to ClickHouse in the [bike lab](../postgis-fdw-bike/) applies here too. That is the question worth ending on.

### 📄 License

[MIT](../../LICENSE) — same as the rest of the repository. The dbpedia
embeddings are fetched at run time from Hugging Face under their own terms and
are not redistributed here.

---

## 한국어

Managed Postgres 카탈로그에는 벡터 확장이 **셋** 올라와 있습니다. 그중 실제로
쓸 수 있는 것은 하나뿐이고, 그 사실을 알아낸 것이 이 랩의 첫 번째 결과입니다.

| 확장 | 카탈로그 | 실제 서비스 | |
|---|---|---|---|
| `vector` | 0.8.2 | **0.8.5, 설치·동작** | pgvector — `hnsw`, `ivfflat` |
| `vchord` | 1.1.1 | ❌ **생성 불가** | VectorChord — `shared_preload_libraries` 필요 |
| `vchord_bm25` | 0.3.0 | ❌ 같은 이유 | BM25를 접근 방법으로 |

```text
postgres=> CREATE EXTENSION vchord;
ERROR:  vchord must be loaded via shared_preload_libraries.

postgres=> ALTER SYSTEM SET shared_preload_libraries = '…,vchord';
ERROR:  ALTER SYSTEM is not allowed in this environment
```

서비스가 미리 로드하는 것은 `pg_cron, pg_stat_statements, pg_stat_ch`뿐이고
사용자가 바꿀 수 없습니다. **확장 카탈로그에 있다는 것과 쓸 수 있다는 것은 다른
얘기입니다** — 그것을 전제로 아키텍처를 짜기 전에 알아둘 만합니다.

그 옆에서 ClickHouse는 26.4부터 usearch 기반 HNSW인 `vector_similarity`
인덱스를 갖고 있습니다. 같은 100만 벡터를 Postgres에서 세 가지로, ClickHouse에서
네 번째 방식으로 색인할 수 있다는 뜻이고, 이 랩이 답하는 질문은 "무엇이 제일
빠른가"가 아니라 **선이 어디인가**입니다 — 벡터 검색은 어느 규모부터 Postgres의
일이 아니게 되며, VectorChord는 그 선을 옮기는가.

> **상태: 2026-08-23에 두 실제 제품에서 끝까지 실행했습니다.**
> ClickHouse Managed Postgres(PostgreSQL 18.4, pgvector 0.8.5)와 ClickHouse
> Cloud 26.4.1. 아래에서 단위가 붙은 수치는 전부 거기서 측정한 것이며, 노트북
> 수치도 벤더 인용도 아닙니다.

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
cp config.env.example config.env && $EDITOR config.env
```

**ClickHouse에서** — [`clickhouse/01-load-dbpedia.sql`](clickhouse/01-load-dbpedia.sql)을
SQL 콘솔에 붙여넣습니다. `vec.dbpedia`를 만들고 Hugging Face에서 적재한 뒤
`vector_similarity` 인덱스를 추가합니다.

**Postgres에서:**

```bash
./scripts/psql.sh -f /sql/01-schema.sql
./scripts/psql.sh -v ch_host=… -v ch_pass=… -f /sql/02-load-from-clickhouse.sql
./scripts/psql.sh -f /sql/03-ground-truth.sql     # 정답셋 + 측정 하네스

./scripts/psql.sh -f /sql/10-pgvector-hnsw.sql
./scripts/psql.sh -f /sql/11-pgvector-ivfflat.sql
./scripts/psql.sh -f /sql/12-vectorchord.sql
```

이어서 [`clickhouse/02-compare.sql`](clickhouse/02-compare.sql)이 ClickHouse
쪽을 같은 기준으로 측정합니다.

계정이 아직 없다면 `./scripts/local-postgres.sh up`이 두 확장이 든 컨테이너를
띄웁니다. ClickHouse 비교를 뺀 전부가 거기서 돕니다.

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

**실제 제품에서** 측정했습니다. ClickHouse Managed Postgres(PostgreSQL 18.4,
pgvector 0.8.5)와 ClickHouse Cloud 26.4.1에 Parquet 파일 하나 —
**38,462행 × 1536차원** — 를 양쪽에 적재했습니다. 워밍 후 수치입니다(아래 마지막
항목 참조).

**Postgres**

| 방법 | 빌드 | recall@10 | ms / 쿼리 | 인덱스 크기 |
|---|---|---|---|---|
| 완전탐색, 인덱스 없음 | — | 1.000 | **375.1** | — (테이블 322 MB) |
| `hnsw`, `ef_search=20` | 68.4초 | 0.975 | **0.99** | 300 MB |
| `hnsw`, `ef_search=40` | 〃 | 0.975 | 1.45 | 300 MB |
| `hnsw`, `ef_search=100` | 〃 | 0.980 | 2.90 | 300 MB |
| `ivfflat`, `probes=1` | 11.4초 | 0.700 | 1.05 | 301 MB |
| `ivfflat`, `probes=10` | 〃 | 0.975 | 7.33 | 301 MB |
| `ivfflat`, `probes=30` | 〃 | 0.995 | 21.44 | 301 MB |
| VectorChord | — | — | — | **사용 불가** |

**ClickHouse**, 같은 행, `vector_similarity('hnsw','cosineDistance',1536,'bf16',16,64)`

| | |
|---|---|
| Hugging Face에서 적재 | 44초 |
| 인덱스 빌드 | 29초 |
| 저장 | 디스크 305.9 MiB — 데이터 215.3 MiB + **인덱스 90.6 MiB** |
| recall@10 | 0.985 |
| 서버 측 지연 | **약 530 ms**, 38,462행 중 25,880행을 읽음 |

네 가지가 나오는데, 넷 다 흔히 예상하는 것과 다릅니다.

**같은 recall에서 HNSW가 IVFFlat보다 5배 빠릅니다.** 둘 다 0.975에 도달하는데
`ef_search=40`이 1.45ms, `probes=10`이 7.33ms입니다. IVFFlat을 0.995까지 밀면
21.44ms가 들고, 그쯤이면 인덱스가 제 값을 못 합니다. HNSW는 그 대가로 6배 긴
빌드 시간을 냈습니다.

**ClickHouse 벡터 인덱스는 이 규모에서 경쟁이 안 되고, 실행 계획이 이유를
말해줍니다.** `EXPLAIN indexes=1`을 보면 인덱스는 동작합니다 — granule을 24개에서
6개로 프루닝합니다. 그런데도 38,462행 중 25,880행을 읽고 서버 측 약 530ms가
걸립니다. 기본값 `GRANULARITY 100000000` 때문에 작은 파트에는 인덱스 인스턴스가
거의 만들어지지 않아 프루닝이 거칩니다. Postgres의 0.99ms와 견줄 상황이
아닙니다. **38,000행에서 벡터는 Postgres에 있어야 하고**, "선이 어디인가"라는 이
랩의 질문은 하한을 얻었습니다 — 여기보다 한참 위입니다.

**압축하는 것은 ClickHouse 인덱스뿐입니다.** Postgres 인덱스는 322 MB 테이블에
300~301 MB로 나왔습니다. HNSW도 IVFFlat도 전체 정밀도 벡터를 그대로 갖습니다.
ClickHouse의 `bf16` 인덱스는 같은 데이터에 90.6 MiB입니다. 그리고 임베딩 자체는
거의 압축되지 않습니다 — 239.5 MiB에서 215.3 MiB, 약 10%입니다. 고르게 분포한
실수에는 코덱이 찾아낼 규칙이 없기 때문입니다. 10억 개를 담는 엔진이 어디든 그
값은 치러야 합니다.

**첫 측정은 틀립니다.** 로컬 컨테이너 예행연습에서 HNSW가 5.6ms로 나왔는데,
워밍 후 수치의 3배였습니다. 인덱스를 갓 만들어 페이지 캐시가 비어 있었기
때문입니다. 위 수치는 전부 워밍 후입니다. 어느 쪽인지 밝히지 않는 벤치마크는
필요한 것을 말해주지 않는 벤치마크입니다.

### 물릴 만한 것 여섯 가지

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
| ✅ 실제 제품에서 검증 | `vchord` 생성 불가와 `ALTER SYSTEM` 거부, `url()`로 ClickHouse Cloud에 HF Parquet 적재, `vector_similarity` 인덱스와 실행 계획, `pg_clickhouse`로 Managed Postgres에 끌어오기, pgvector `hnsw`·`ivfflat`의 빌드·크기·recall·지연, 위 표의 모든 수치 |
| ❌ 막힘 (건너뛴 것이 아님) | **VectorChord.** 패키지는 있고 `shared_preload_libraries`에만 빠져 있어 나중에 풀릴 수 있으므로 `sql/12-vectorchord.sql`은 남겨둡니다 |
| ❌ 미실행 | 100만 행 전체. 26개 중 Parquet 1개만 사용 |
| ❌ 미작성 | `vchord_bm25` 하이브리드 단계 — 어차피 같은 이유로 막혀 있음 |

적재 경로도 측정했고, 그것이
[`sql/02-load-from-clickhouse.sql`](sql/02-load-from-clickhouse.sql)이 FDW를
쓰는 이유입니다. ClickHouse가 Hugging Face에서 **44초**에 읽었고,
`pg_clickhouse`가 38,462행 전부를 Postgres로 **38.9초**에 옮겼습니다. 대안인
Parquet→텍스트 파이프라인→`COPY`는 예행연습에서 **분당 약 3,000행**이었습니다 —
모든 float이 십진 문자열이 되기 때문입니다. 같은 데이터로 39초 대신 13분입니다.

### 다음

- **100만 행 전체.** 여기 있는 것은 방법론이고, 흥미로운 수치는 6 GB 작업집합이 편하게 들어가지 않게 되는 100만 행에서 나옵니다.
- **`vchord_bm25`.** 데이터에 본문 텍스트가 함께 있어서 어휘+벡터 하이브리드 검색이 인덱스 하나 거리이고, [`usecase/fulltext-search`](../../usecase/fulltext-search/)라는 비교 대상도 이미 있습니다.
- **벡터가 어디에 있어야 하는가.** 임베딩이 검색만 되고 갱신되지 않는다면, [자전거 랩](../postgis-fdw-bike/)에서 집계를 ClickHouse로 옮긴 논리가 여기에도 적용됩니다. 마지막에 던질 만한 질문입니다.

### 📄 라이선스

[MIT](../../LICENSE) — 저장소 전체와 동일합니다. dbpedia 임베딩은 실행 시점에
Hugging Face에서 각자의 약관으로 받아오며 여기 재배포하지 않습니다.
