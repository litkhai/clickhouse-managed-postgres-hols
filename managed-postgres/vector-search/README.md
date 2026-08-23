# Vector search — pgvector, VectorChord and ClickHouse

[English](#english) | [한국어](#한국어)

---

## English

Managed Postgres ships **two** vector engines, not one. That is the fact this
lab is built around.

| Extension | Version | What it is |
|---|---|---|
| `vector` | 0.8.2 | **pgvector** — the default. `hnsw` and `ivfflat` access methods |
| `vchord` | 1.1.1 | **VectorChord** — IVF with RaBitQ quantisation, `vchordrq` |
| `vchord_bm25` | 0.3.0 | BM25 ranking as an access method (lexical, not covered here yet) |

Alongside them, ClickHouse has had a `vector_similarity` index — HNSW backed
by usearch — since 26.4. So the same million vectors can be indexed three ways
in Postgres and a fourth way in ClickHouse, and the question this lab answers
is not "which is fastest" but **where the line is**: at what size does vector
search stop belonging in Postgres, and does VectorChord move that line?

> **Status: the Postgres half is verified, the ClickHouse half is not.**
> See [What has actually been run](#what-has-actually-been-run). Every number
> below that carries a unit was measured; nothing is quoted from a vendor
> benchmark without saying so.

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

Measured on **31,000 rows × 1536 dimensions**, PostgreSQL 17.4 with pgvector
0.8.0 and VectorChord 0.4.3, in a container on a laptop, by running the
`sql/1*.sql` files in this directory. Warm — see the last finding below. The
shape is trustworthy; the third decimal place is not, and at this size every
method is fast enough that the ranking matters more than the numbers.

| Method | Build | recall@10 | ms / query | Index size |
|---|---|---|---|---|
| exact, no index | — | 1.000 | **99.7** | — (table 261 MB) |
| pgvector `hnsw`, `ef_search=20` | 29.3 s | 0.995 | 1.56 | 242 MB |
| pgvector `hnsw`, `ef_search=40` | " | 0.995 | 1.79 | 242 MB |
| pgvector `hnsw`, `ef_search=100` | " | 1.000 | 3.79 | 242 MB |
| pgvector `ivfflat`, `probes=1` | 2.8 s | 0.715 | 1.53 | 243 MB |
| pgvector `ivfflat`, `probes=10` | " | 0.965 | 3.77 | 243 MB |
| pgvector `ivfflat`, `probes=30` | " | 0.990 | 8.55 | 243 MB |
| VectorChord, `probes=1` | 8.9 s | 0.700 | **0.10** | 253 MB |
| VectorChord, `probes=10` | " | 0.965 | **0.19** | 253 MB |
| VectorChord, `probes=30` | " | 0.985 | **0.38** | 253 MB |

Four things fall out, and none of them is the one people expect.

**Compare at equal recall, and only at equal recall.** IVFFlat and VectorChord
both land on exactly 0.965 at `probes=10`, which makes that row the honest
comparison in the whole table: **3.77 ms against 0.19 ms, a factor of twenty.**
Against HNSW the gap is smaller but still large — 1.79 ms at 0.995 versus
0.38 ms at 0.985. Same direction as VectorChord's published claims, at a
fraction of the scale they were measured on, which is the most one small run
can honestly say.

**Nothing compressed anything.** All three indexes came out at 242–253 MB
against a 261 MB table. RaBitQ compresses what is *scanned*, not what is
*stored*: the full vectors stay for re-ranking. VectorChord's headline "1B
vectors in 64 MB" is about the resident working set, not disk, and reading it
as a storage claim will lead you somewhere wrong.

**Build cost and query cost trade against each other.** IVFFlat built in a
tenth of HNSW's time and then paid it back at every query: reaching 0.990 cost
8.55 ms, where HNSW held 0.995 at 1.79 ms. Neither is better; they are
different points on one curve, and which you want depends on whether the index
is built once or continuously.

**The first measurement you take is wrong.** An earlier pass of this same
comparison put HNSW at 5.6 ms — three times its warm number — because the index
had just been built and nothing was in the page cache. Every figure above is
from a second run onward. If a benchmark does not say whether it was warm, it
is not telling you the thing you need.

### Four things that will bite you

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
| ✅ Verified | The Hugging Face source is reachable without a key; the Parquet schema; loading into Postgres; all three index types building, with times and sizes; ground truth and recall harness; the numbers in the table above |
| ⚠️ Local versions differ | Verified against pgvector 0.8.0 / VectorChord 0.4.3 in a container. Managed Postgres publishes **0.8.2 / 1.1.1** |
| ❌ Not yet run | The ClickHouse half — [`clickhouse/*.sql`](clickhouse/) is written from the documentation. `vector_similarity` syntax and settings are as documented for 26.4, not as executed |
| ❌ Not yet written | The full million rows, and the `vchord_bm25` hybrid-search stage |

The load path was measured too, and it is the reason
[`sql/02-load-from-clickhouse.sql`](sql/02-load-from-clickhouse.sql) goes
through the FDW: piping Parquet through a text pipeline into `COPY` managed
roughly **3,000 rows a minute** at 1536 dimensions, because every float becomes
a decimal string. A million rows that way is not an afternoon.

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

Managed Postgres에는 벡터 엔진이 **하나가 아니라 둘** 들어 있습니다. 이 랩은
그 사실 위에 서 있습니다.

| 확장 | 버전 | 정체 |
|---|---|---|
| `vector` | 0.8.2 | **pgvector** — 기본. `hnsw`, `ivfflat` 접근 방법 |
| `vchord` | 1.1.1 | **VectorChord** — RaBitQ 양자화 IVF, `vchordrq` |
| `vchord_bm25` | 0.3.0 | BM25 랭킹을 접근 방법으로 (어휘 검색, 이 랩에선 아직 미포함) |

그 옆에서 ClickHouse는 26.4부터 usearch 기반 HNSW인 `vector_similarity`
인덱스를 갖고 있습니다. 같은 100만 벡터를 Postgres에서 세 가지로, ClickHouse에서
네 번째 방식으로 색인할 수 있다는 뜻이고, 이 랩이 답하는 질문은 "무엇이 제일
빠른가"가 아니라 **선이 어디인가**입니다 — 벡터 검색은 어느 규모부터 Postgres의
일이 아니게 되며, VectorChord는 그 선을 옮기는가.

> **상태: Postgres 쪽은 검증했고 ClickHouse 쪽은 아직입니다.**
> [실제로 돌려본 것](#실제로-돌려본-것) 참조. 아래에서 단위가 붙은 수치는 전부
> 실측이며, 벤더 벤치마크를 인용할 때는 그렇다고 밝혔습니다.

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

**31,000행 × 1536차원**, PostgreSQL 17.4 + pgvector 0.8.0 + VectorChord 0.4.3,
노트북 컨테이너에서 이 디렉토리의 `sql/1*.sql`을 실행해 얻었습니다. 워밍 후
수치입니다(아래 마지막 항목 참조). 경향은 신뢰할 만하나 소수점 셋째 자리는
아니며, 이 규모에서는 어느 방법이든 충분히 빨라 절대 수치보다 순위가 중요합니다.

| 방법 | 빌드 | recall@10 | ms / 쿼리 | 인덱스 크기 |
|---|---|---|---|---|
| 완전탐색, 인덱스 없음 | — | 1.000 | **99.7** | — (테이블 261 MB) |
| pgvector `hnsw`, `ef_search=20` | 29.3초 | 0.995 | 1.56 | 242 MB |
| pgvector `hnsw`, `ef_search=40` | 〃 | 0.995 | 1.79 | 242 MB |
| pgvector `hnsw`, `ef_search=100` | 〃 | 1.000 | 3.79 | 242 MB |
| pgvector `ivfflat`, `probes=1` | 2.8초 | 0.715 | 1.53 | 243 MB |
| pgvector `ivfflat`, `probes=10` | 〃 | 0.965 | 3.77 | 243 MB |
| pgvector `ivfflat`, `probes=30` | 〃 | 0.990 | 8.55 | 243 MB |
| VectorChord, `probes=1` | 8.9초 | 0.700 | **0.10** | 253 MB |
| VectorChord, `probes=10` | 〃 | 0.965 | **0.19** | 253 MB |
| VectorChord, `probes=30` | 〃 | 0.985 | **0.38** | 253 MB |

네 가지가 나오는데, 넷 다 흔히 예상하는 것과 다릅니다.

**같은 recall에서만 비교하십시오.** IVFFlat과 VectorChord가 `probes=10`에서
정확히 0.965로 일치하는데, 그 행이 이 표 전체에서 가장 정직한 비교입니다 —
**3.77ms 대 0.19ms, 20배.** HNSW와의 격차는 그보다 작지만 여전히 큽니다:
0.995에서 1.79ms 대 0.985에서 0.38ms. VectorChord가 발표한 주장과 같은
방향이되 그들이 측정한 규모의 극히 일부이며, 작은 실행 하나가 정직하게 말할 수
있는 최대치가 그것입니다.

**아무것도 압축되지 않았습니다.** 세 인덱스 모두 242~253 MB로 261 MB 테이블과
비슷합니다. RaBitQ는 *저장되는 것*이 아니라 *스캔되는 것*을 압축합니다 —
재랭킹용 전체 벡터는 그대로 남습니다. "10억 벡터를 64 MB로"는 디스크가 아니라
상주 작업집합 이야기이고, 저장 용량 주장으로 읽으면 잘못된 곳에 도달합니다.

**빌드 비용과 쿼리 비용은 서로 맞바꿔집니다.** IVFFlat은 HNSW의 10분의 1 시간에
만들어졌고 그 값을 매 쿼리마다 갚았습니다. 0.990에 도달하는 데 8.55ms가 들었고,
HNSW는 0.995를 1.79ms에 유지했습니다. 어느 쪽이 낫다기보다 같은 곡선 위의 다른
점이며, 인덱스를 한 번 만드는지 계속 만드는지가 선택을 가릅니다.

**첫 측정은 틀립니다.** 같은 비교의 이전 회차에서 HNSW가 5.6ms로 나왔습니다 —
워밍 후 수치의 3배인데, 인덱스를 갓 만들어 페이지 캐시에 아무것도 없었기
때문입니다. 위 수치는 전부 두 번째 실행 이후의 것입니다. 워밍 여부를 밝히지 않는
벤치마크는 필요한 것을 말해주지 않는 벤치마크입니다.

### 물릴 만한 것 네 가지

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
| ✅ 검증됨 | Hugging Face 원본이 키 없이 접근 가능함, Parquet 스키마, Postgres 적재, 세 인덱스 빌드와 시간·크기, 정답셋과 recall 하네스, 위 표의 수치 |
| ⚠️ 버전 차이 | 컨테이너의 pgvector 0.8.0 / VectorChord 0.4.3에서 검증. Managed Postgres는 **0.8.2 / 1.1.1** |
| ❌ 미실행 | ClickHouse 쪽 — [`clickhouse/*.sql`](clickhouse/)은 문서 기반으로 작성. `vector_similarity` 문법과 설정은 26.4 문서 그대로이며 실행 결과가 아님 |
| ❌ 미작성 | 100만 행 전체, `vchord_bm25` 하이브리드 검색 단계 |

적재 경로도 측정했고, 그것이
[`sql/02-load-from-clickhouse.sql`](sql/02-load-from-clickhouse.sql)이 FDW를
쓰는 이유입니다. Parquet을 텍스트 파이프라인으로 흘려 `COPY`하면 1536차원에서
**분당 약 3,000행**이었습니다 — 모든 float이 십진 문자열이 되기 때문입니다.
그 방식으로 100만 행은 오후 한나절에 끝나지 않습니다.

### 다음

- **100만 행 전체.** 여기 있는 것은 방법론이고, 흥미로운 수치는 6 GB 작업집합이 편하게 들어가지 않게 되는 100만 행에서 나옵니다.
- **`vchord_bm25`.** 데이터에 본문 텍스트가 함께 있어서 어휘+벡터 하이브리드 검색이 인덱스 하나 거리이고, [`usecase/fulltext-search`](../../usecase/fulltext-search/)라는 비교 대상도 이미 있습니다.
- **벡터가 어디에 있어야 하는가.** 임베딩이 검색만 되고 갱신되지 않는다면, [자전거 랩](../postgis-fdw-bike/)에서 집계를 ClickHouse로 옮긴 논리가 여기에도 적용됩니다. 마지막에 던질 만한 질문입니다.

### 📄 라이선스

[MIT](../../LICENSE) — 저장소 전체와 동일합니다. dbpedia 임베딩은 실행 시점에
Hugging Face에서 각자의 약관으로 받아오며 여기 재배포하지 않습니다.
