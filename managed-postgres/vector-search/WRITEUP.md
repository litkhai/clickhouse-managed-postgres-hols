# How this comparison was built

Source material for a longer article. Written in the order the work happened,
with the wrong turns left in, because the wrong turns are where the findings
came from.

[English](#english) | [한국어](#한국어)

---

## English

### 1. The question

"Should vectors live in Postgres or in ClickHouse?" is a bad question. Every
answer to it is "it depends", and nobody says on what.

The question worth asking is narrower: **where is the line?** At some size,
vector search stops being something an operational Postgres should be doing.
Below that line the answer is obviously Postgres — the data is already there,
the join to the rest of your schema is free, and one fewer system is one fewer
system. Above it, something has to change.

So the lab was designed to find a number, not to declare a winner.

### 2. Why the premise changed before any measurement

ClickHouse Managed Postgres publishes an extension catalogue of about 95
entries, and three of them are vector-related:

| | |
|---|---|
| `vector` 0.8.2 | pgvector, the default |
| `vchord` 1.1.1 | VectorChord — IVF with RaBitQ quantisation |
| `vchord_bm25` 0.3.0 | BM25 as an access method |

That is an interesting choice by the platform. Including VectorChord alongside
pgvector says something: pgvector's HNSW is not considered the end of the
story. VectorChord's published benchmarks claim 5× query throughput and 16×
faster index builds, and 1 billion vectors indexed in 64 MB against pgvector's
1 TB. If any of that survives contact with a real service, the line moves.

It does not survive contact, because you cannot turn it on:

```text
postgres=> CREATE EXTENSION vchord;
ERROR:  vchord must be loaded via shared_preload_libraries.

postgres=> ALTER SYSTEM SET shared_preload_libraries = '…,vchord';
ERROR:  ALTER SYSTEM is not allowed in this environment
```

The service preloads `pg_cron, pg_stat_statements, pg_stat_ch` and nothing
else. The package is installed — the `.control` file is there, the extension
appears in `pg_available_extensions` — and it is unusable, because loading it
requires a postmaster-context setting that a managed service does not let you
touch.

**Being in the extension catalogue is not the same as being usable.** That is
the first thing worth saying in an article, because a list of 95 extensions
reads like a menu and part of it is not.

`vchord_bm25` is blocked by the same thing, which removes the hybrid
lexical-plus-vector search story too.

### 3. Choosing data that needs no model

The obvious way to build a vector lab is to embed some text. That immediately
drags in an embedding model: an API key, or Ollama, or a GPU. Every one of
those is a reason for someone to give up before the interesting part.

So: use a corpus that is **already embedded**. ClickHouse documents one —
1,000,000 Wikipedia articles from dbpedia with 1536-dimension embeddings from
OpenAI's `text-embedding-3-large`, published as 26 Parquet files on Hugging
Face, no key required.

That choice buys three things at once. No model dependency. A dimension count
(1536) large enough that storage and memory actually matter. And a corpus with
titles and body text still attached, so the lexical half of a hybrid-search
lab is one index away — if the platform ever allows it.

### 4. Getting a million vectors into two databases

The ingestion route is the one the neighbouring bike lab already established:
ClickHouse reads the Parquet directly with `url()`, and Postgres pulls from
ClickHouse through `pg_clickhouse`. No download step, no local disk.

Two format traps, both of which produce errors that point at the wrong thing.

**Hugging Face redirects more than once.** ClickHouse permits one redirect by
default and then fails:

```text
Code: 483. Too many redirects while trying to access …
The table structure cannot be extracted from a Parquet format file.
```

The second sentence is the misleading one. Nothing is wrong with the Parquet.
`max_http_get_redirects = 10` fixes it — but over Cloud's HTTPS interface you
cannot send it as a `SET` statement, because the endpoint rejects
multi-statement bodies (`Syntax error (Multi-statements are not allowed)`). It
has to be a query parameter: `POST /?max_http_get_redirects=10`.

**pg_clickhouse hands back a Postgres array; pgvector wants brackets.**

```text
ERROR:  invalid input syntax for type vector: "{-0.0018529714,0.022446368,…}"
DETAIL:  Vector contents must start with "[".
```

`Array(Float32)` surfaces as `{…}`. pgvector 0.8.x has no array-to-vector cast,
so the shortest correct bridge is `translate(embedding::text, '{}', '[]')`.

With those out of the way the numbers are good: ClickHouse read one Parquet
file from Hugging Face in **44 s**, and the FDW moved all 38,462 rows into
Postgres in **38.9 s**.

The alternative is worth quoting for contrast. A rehearsal that piped Parquet
through a text pipeline into `COPY` managed roughly **3,000 rows a minute**,
because every one of 1536 floats becomes a decimal string and each row carries
about 20 KB of text. Same data: thirteen minutes instead of thirty-nine
seconds.

### 5. Measuring it in a way that means something

**A vector benchmark that reports speed without recall is measuring nothing.**
Any approximate index can be made arbitrarily fast by looking at fewer
candidates. Latency alone is a free parameter.

So before comparing anything:

1. Twenty query vectors are drawn from the corpus itself, ordered by `md5(id)`
   so the set is reproducible and identical on both engines.
2. Their **exact** top-10 is computed by brute force with parallelism off, and
   stored. That table is the reference.

Everything else reports recall@10 against it, and the comparison happens at
**matched recall** rather than at whatever each index does with its defaults.

The ClickHouse side needs the same care in a different place. Its ground-truth
query has to run with `use_skip_indexes = 0`; let ClickHouse answer the
reference query using its own vector index and recall is 1.000 by
construction, which measures the index against itself.

### 6. pgvector, measured on the real service

PostgreSQL 18.4, pgvector 0.8.5, 38,462 rows × 1536 dimensions.

| Method | Build | recall@10 | ms / query | Index |
|---|---|---|---|---|
| exact, no index | — | 1.000 | 375.1 | — (table 322 MB) |
| `hnsw`, `ef_search=20` | 68.4 s | 0.975 | **0.99** | 300 MB |
| `hnsw`, `ef_search=40` | " | 0.975 | 1.45 | 300 MB |
| `hnsw`, `ef_search=100` | " | 0.980 | 2.90 | 300 MB |
| `ivfflat`, `probes=1` | 11.4 s | 0.700 | 1.05 | 301 MB |
| `ivfflat`, `probes=10` | " | 0.975 | 7.33 | 301 MB |
| `ivfflat`, `probes=30` | " | 0.995 | 21.44 | 301 MB |

The row that matters is the pair at 0.975: **HNSW 1.45 ms against IVFFlat
7.33 ms.** Five times, at identical recall. IVFFlat can reach 0.995 but it
costs 21.44 ms to get there, by which point it is only fourteen times better
than not having an index at all.

HNSW paid for that with a build six times longer — 68 s against 11 s. That is
the actual trade, and it is decided by whether your index is built once or
rebuilt continuously, not by which number is smaller.

### 7. Nothing compresses, except one thing

All the Postgres indexes came out at 300–301 MB against a 322 MB table. HNSW
keeps full-precision vectors in its graph; IVFFlat keeps them in its cells.
Neither compresses.

VectorChord's headline — 1 billion vectors in 64 MB — is easy to misread as a
storage claim. It is not. RaBitQ compresses what is **scanned**, not what is
**stored**: the compressed codes are what the search walks, and the full
vectors stay for re-ranking. A laptop rehearsal confirmed it, with VectorChord
producing the *largest* index of the three (253 MB against pgvector's 242 and
243).

The one thing that does compress is ClickHouse's index: **90.6 MiB** for the
same data, because `bf16` quantisation is the default and the documentation
reports recall matching Float32.

And a detail worth an aside in any article: **the embeddings themselves barely
compress.** 239.5 MiB uncompressed to 215.3 MiB — about 10%. Uniformly
distributed floats give a codec nothing to find. Whoever holds a billion of
these pays for a billion of these, in any engine.

### 8. ClickHouse's vector index, and reading its plan

This is where the expected answer failed.

ClickHouse Cloud 26.4.1, same rows,
`vector_similarity('hnsw', 'cosineDistance', 1536, 'bf16', 16, 64)`. The index
built in 29 s and reached recall 0.985 — right in the range pgvector was in.

And it took **~530 ms per query, server-side**, against pgvector's 0.99 ms.

The temptation is to conclude the index is not being used. `EXPLAIN indexes=1`
says otherwise:

```text
Skip
  Name: emb_idx
  Description: vector_similarity GRANULARITY 100000000
  Parts: 1/1
  Granules: 6/24
```

It is working. It pruned 24 granules to 6. And the query still read **25,880 of
38,462 rows** — two thirds of the table — because the default granularity of
100,000,000 means a small part gets almost no index instances built, so each
surviving granule is enormous.

That is a much more interesting finding than "ClickHouse is slow at vectors".
The mechanism is visible, it is a tuning artefact of a default chosen for
billion-row parts, and it says the feature is built for a scale this test is
nowhere near.

### 9. So where is the line?

The honest answer is that this run did not find it — it found a **lower
bound**.

At 38,462 rows the answer is unambiguous: the vectors belong in Postgres. One
millisecond against five hundred is not a trade-off, it is a decision. And
that is at 1536 dimensions, which is the expensive end of the embedding space.

Where the crossover actually is depends on things this test held constant — how
many parts the ClickHouse table has, what granularity the index is given,
whether the working set still fits in the Postgres instance's memory. The
interesting version of this experiment is the same harness at 1M and 10M rows,
watching for where the 375 ms exact-scan baseline and the ClickHouse number
cross under each other.

What can be said now: **the line is well above where most people assume it
is.** If your corpus is tens of thousands of documents, the pgvector answer is
not a compromise.

### 10. Two ways a laptop told me the wrong thing

Both worth a paragraph in an article, because both look like data.

**Cold caches.** A rehearsal on a container put HNSW at 5.6 ms per query. The
warm number is 1.79 ms. The index had just been built and nothing was in the
page cache. Three times wrong, and nothing about the output says so — the
figure is real, it just answers a question nobody asked. A benchmark that does
not state whether it was warm is not telling you the thing you need.

**Hiding an index the clever way.** Comparing three indexes means running each
one alone, and the planner picks by cost and takes no instructions. The obvious
shortcut is to toggle `pg_index.indisvalid` off for the two you do not want.

It does not work, and it fails silently. Plan caching inside PL/pgSQL keeps
handing back the previous plan, so every method reports the sequential-scan
number. The result was a clean-looking table of three different methods with
identical recall and identical latency — which is exactly what a real result
would look like if the three were equivalent.

The fix is unglamorous: drop the other indexes and rebuild. Forty-five seconds
per cycle, and the numbers are real.

**And the largest version of the same mistake**: the entire first pass of this
lab was measured on a laptop container, and the write-up drew conclusions from
it. Every one of the three headline findings above — VectorChord unusable,
ClickHouse's granularity problem, HNSW beating IVFFlat five to one — is
invisible on a laptop. Two of them are properties of the managed service, not
of the software.

### 11. Numbers worth quoting

| | |
|---|---|
| Corpus | dbpedia, 1M articles, 1536-dim `text-embedding-3-large`, 26 Parquet files, no API key |
| Tested at | 38,462 rows (one file) |
| Load: HF → ClickHouse | 44 s |
| Load: ClickHouse → Postgres via FDW | 38.9 s |
| Load: Parquet → text → `COPY` (rehearsal) | ~3,000 rows/min |
| Postgres table | 322 MB — 16 MB heap, 306 MB TOAST |
| Exact scan | 375.1 ms/query |
| pgvector HNSW | 68.4 s build, 300 MB, 0.975 @ 1.45 ms |
| pgvector IVFFlat | 11.4 s build, 301 MB, 0.975 @ 7.33 ms |
| ClickHouse `vector_similarity` | 29 s build, 90.6 MiB, 0.985 @ ~530 ms |
| ClickHouse rows read despite index | 25,880 of 38,462 |
| Embedding compression in ClickHouse | 239.5 → 215.3 MiB (~10%) |
| VectorChord | unavailable — not in `shared_preload_libraries` |

### 12. What is left

- **The full million.** Everything here is method. The number this lab exists to find is above 38k rows and the harness is ready for it.
- **Where the crossover is.** Run 1M and 10M with the same twenty queries and watch the two curves.
- **ClickHouse with a sane granularity.** The 100,000,000 default is the whole story of section 8. Setting it explicitly for a small table is an obvious next experiment and might change the conclusion entirely.
- **VectorChord, if it is ever preloaded.** `sql/12-vectorchord.sql` is kept for that day. On a container that preloads it, VectorChord hit recall 0.965 at 0.19 ms where IVFFlat needed 3.77 ms for the same recall — twenty times, which is worth re-testing properly if the platform opens it up.
- **Hybrid search.** `vchord_bm25` plus the article text the corpus already carries. Same blocker.

---

## 한국어

### 1. 질문

"벡터는 Postgres에 둬야 하나 ClickHouse에 둬야 하나"는 나쁜 질문입니다. 모든
답이 "경우에 따라 다르다"이고, 무엇에 따라 다른지는 아무도 말하지 않습니다.

물어볼 만한 질문은 더 좁습니다. **선이 어디인가?** 어느 규모부터 벡터 검색은
운영용 Postgres가 할 일이 아니게 됩니다. 그 아래에서는 답이 명백히
Postgres입니다 — 데이터가 이미 거기 있고, 나머지 스키마와의 조인이 공짜이며,
시스템 하나가 줄어듭니다. 그 위에서는 무언가 바뀌어야 합니다.

그래서 이 랩은 승자를 선언하는 게 아니라 **숫자 하나를 찾도록** 설계했습니다.

### 2. 측정을 시작하기도 전에 전제가 바뀐 이유

ClickHouse Managed Postgres는 약 95개 확장을 공개하고, 그중 셋이 벡터
관련입니다.

| | |
|---|---|
| `vector` 0.8.2 | pgvector, 기본 |
| `vchord` 1.1.1 | VectorChord — RaBitQ 양자화 IVF |
| `vchord_bm25` 0.3.0 | BM25를 접근 방법으로 |

플랫폼의 흥미로운 선택입니다. pgvector 옆에 VectorChord를 넣었다는 것은
pgvector HNSW가 이야기의 끝이 아니라고 본다는 뜻입니다. VectorChord가 발표한
벤치마크는 쿼리 처리량 5배, 인덱스 빌드 16배, 10억 벡터를 64 MB로(pgvector는
1 TB) 색인한다고 주장합니다. 그중 하나라도 실제 서비스에서 살아남으면 선이
움직입니다.

살아남지 못합니다. **켤 수가 없기 때문입니다.**

```text
postgres=> CREATE EXTENSION vchord;
ERROR:  vchord must be loaded via shared_preload_libraries.

postgres=> ALTER SYSTEM SET shared_preload_libraries = '…,vchord';
ERROR:  ALTER SYSTEM is not allowed in this environment
```

서비스가 미리 로드하는 것은 `pg_cron, pg_stat_statements, pg_stat_ch`뿐입니다.
패키지는 설치돼 있습니다 — `.control` 파일이 있고 `pg_available_extensions`에도
나옵니다 — 그런데 쓸 수 없습니다. 로드하려면 postmaster 컨텍스트 설정이 필요한데
관리형 서비스는 그걸 만지게 해주지 않기 때문입니다.

**확장 카탈로그에 있다는 것과 쓸 수 있다는 것은 다릅니다.** 95개 목록은 메뉴판
처럼 읽히지만 일부는 메뉴가 아니라는 것 — 글에서 먼저 말할 만한 이야기입니다.

`vchord_bm25`도 같은 이유로 막히고, 그래서 어휘+벡터 하이브리드 검색 이야기도
함께 사라집니다.

### 3. 모델이 필요 없는 데이터 고르기

벡터 랩을 만드는 뻔한 방법은 텍스트를 임베딩하는 것입니다. 그 순간 임베딩 모델이
딸려옵니다 — API 키, 혹은 Ollama, 혹은 GPU. 하나같이 흥미로운 부분에 닿기 전에
포기할 이유가 됩니다.

그래서 **이미 임베딩된** 코퍼스를 씁니다. ClickHouse가 문서화해 둔 것이 있습니다.
dbpedia 위키백과 문서 100만 건에 OpenAI `text-embedding-3-large`의 1536차원
임베딩, Hugging Face에 Parquet 26개 파일, 키 불필요.

이 선택이 세 가지를 한꺼번에 삽니다. 모델 의존성 없음. 저장과 메모리가 실제로
문제가 될 만큼 큰 차원 수(1536). 그리고 제목과 본문이 그대로 붙어 있어서,
플랫폼이 언젠가 허용한다면 하이브리드 검색의 어휘 절반이 인덱스 하나 거리에
있다는 것.

### 4. 100만 벡터를 두 데이터베이스에 넣기

적재 경로는 옆의 자전거 랩이 이미 확립한 것입니다. ClickHouse가 `url()`로
Parquet을 직접 읽고, Postgres가 `pg_clickhouse`로 ClickHouse에서 끌어옵니다.
다운로드 단계도, 로컬 디스크도 없습니다.

형식 관련 함정 둘. 둘 다 엉뚱한 곳을 가리키는 오류를 냅니다.

**Hugging Face는 리다이렉트를 한 번 이상 합니다.** ClickHouse 기본값은 1회이고
그 다음 실패합니다.

```text
Code: 483. Too many redirects while trying to access …
The table structure cannot be extracted from a Parquet format file.
```

두 번째 문장이 사람을 속입니다. Parquet에는 아무 문제가 없습니다.
`max_http_get_redirects = 10`으로 해결되는데, Cloud의 HTTPS 인터페이스로는 `SET`
문으로 보낼 수 없습니다. 엔드포인트가 다중 문장 본문을 거부하기 때문입니다
(`Syntax error (Multi-statements are not allowed)`). 쿼리 파라미터여야 합니다:
`POST /?max_http_get_redirects=10`.

**pg_clickhouse는 Postgres 배열을 주고 pgvector는 대괄호를 원합니다.**

```text
ERROR:  invalid input syntax for type vector: "{-0.0018529714,0.022446368,…}"
DETAIL:  Vector contents must start with "[".
```

`Array(Float32)`가 `{…}`로 올라옵니다. pgvector 0.8.x에는 배열→vector 캐스팅이
없어서, 가장 짧은 다리가 `translate(embedding::text, '{}', '[]')`입니다.

이 둘을 넘기고 나면 수치는 좋습니다. ClickHouse가 Parquet 파일 하나를 Hugging
Face에서 **44초**에 읽었고, FDW가 38,462행 전부를 Postgres로 **38.9초**에
옮겼습니다.

대비를 위해 인용할 만한 대안이 있습니다. Parquet을 텍스트 파이프라인으로 흘려
`COPY`한 예행연습은 **분당 약 3,000행**이었습니다. 1536개 float이 전부 십진
문자열이 되고 행마다 약 20 KB의 텍스트를 지고 가기 때문입니다. 같은 데이터에
39초 대신 13분입니다.

### 5. 의미 있게 측정하기

**recall 없이 속도만 보고하는 벡터 벤치마크는 아무것도 측정하지 않은
것입니다.** 근사 인덱스는 후보를 덜 보게 하면 원하는 만큼 빨라집니다. 지연은
그 자체로 자유 변수입니다.

그래서 무엇을 비교하기 전에 먼저:

1. 코퍼스 자체에서 쿼리 벡터 20개를 `md5(id)` 순으로 뽑습니다. 재현 가능하고 두
   엔진에서 동일합니다.
2. 각각의 **정확한** top-10을 병렬을 끈 완전탐색으로 구해 저장합니다. 그 표가
   기준입니다.

나머지는 전부 그에 대한 recall@10을 보고하고, 비교는 각 인덱스의 기본 설정이
아니라 **동일 recall**에서 이뤄집니다.

ClickHouse 쪽도 같은 주의가 다른 지점에서 필요합니다. 정답셋 쿼리는
`use_skip_indexes = 0`으로 돌려야 합니다. 기준 쿼리를 ClickHouse 자신의 벡터
인덱스로 답하게 두면 recall은 구조상 1.000이 되고, 그건 인덱스를 자기 자신과
비교한 것입니다.

### 6. 실제 서비스에서 측정한 pgvector

PostgreSQL 18.4, pgvector 0.8.5, 38,462행 × 1536차원.

| 방법 | 빌드 | recall@10 | ms / 쿼리 | 인덱스 |
|---|---|---|---|---|
| 완전탐색, 인덱스 없음 | — | 1.000 | 375.1 | — (테이블 322 MB) |
| `hnsw`, `ef_search=20` | 68.4초 | 0.975 | **0.99** | 300 MB |
| `hnsw`, `ef_search=40` | 〃 | 0.975 | 1.45 | 300 MB |
| `hnsw`, `ef_search=100` | 〃 | 0.980 | 2.90 | 300 MB |
| `ivfflat`, `probes=1` | 11.4초 | 0.700 | 1.05 | 301 MB |
| `ivfflat`, `probes=10` | 〃 | 0.975 | 7.33 | 301 MB |
| `ivfflat`, `probes=30` | 〃 | 0.995 | 21.44 | 301 MB |

중요한 행은 0.975에서 만나는 한 쌍입니다. **HNSW 1.45ms 대 IVFFlat 7.33ms.**
동일 recall에서 5배입니다. IVFFlat도 0.995에 갈 수 있지만 21.44ms가 들고, 그쯤
되면 인덱스가 없는 것보다 14배 나은 정도에 그칩니다.

HNSW는 그 대가로 6배 긴 빌드를 냈습니다 — 68초 대 11초. 그게 실제 거래이고,
어느 숫자가 작은지가 아니라 인덱스를 한 번 만드는지 계속 다시 만드는지가
결정합니다.

### 7. 아무것도 압축되지 않는다, 하나만 빼고

Postgres 인덱스는 322 MB 테이블에 전부 300~301 MB로 나왔습니다. HNSW는 그래프에,
IVFFlat은 셀에 전체 정밀도 벡터를 갖습니다. 둘 다 압축하지 않습니다.

VectorChord의 헤드라인 — 10억 벡터를 64 MB로 — 은 저장 용량 주장으로 오해하기
쉽습니다. 아닙니다. RaBitQ는 **스캔되는 것**을 압축하지 **저장되는 것**을
압축하지 않습니다. 압축 코드는 탐색이 훑는 대상이고, 재랭킹용 전체 벡터는 그대로
남습니다. 노트북 예행연습이 그것을 확인해줬습니다. VectorChord가 셋 중 **가장 큰**
인덱스를 만들었습니다 (253 MB 대 pgvector의 242, 243).

압축하는 유일한 것은 ClickHouse 인덱스입니다. 같은 데이터에 **90.6 MiB**입니다.
`bf16` 양자화가 기본이고 문서는 recall이 Float32와 같다고 보고합니다.

그리고 어떤 글에서든 곁가지로 넣을 만한 사실 하나: **임베딩 자체는 거의 압축되지
않습니다.** 비압축 239.5 MiB에서 215.3 MiB, 약 10%입니다. 고르게 분포한 실수에는
코덱이 찾을 규칙이 없습니다. 10억 개를 가진 쪽은 어느 엔진에서든 10억 개 값을
치릅니다.

### 8. ClickHouse의 벡터 인덱스, 그리고 그 실행 계획 읽기

예상했던 답이 무너진 지점입니다.

ClickHouse Cloud 26.4.1, 같은 행,
`vector_similarity('hnsw', 'cosineDistance', 1536, 'bf16', 16, 64)`. 인덱스는
29초에 만들어졌고 recall 0.985에 도달했습니다 — pgvector와 같은 구간입니다.

그리고 **서버 측 쿼리당 약 530ms**가 걸렸습니다. pgvector의 0.99ms에 대해서요.

인덱스가 안 걸린 것 아니냐고 결론짓고 싶어집니다. `EXPLAIN indexes=1`은 다르게
말합니다.

```text
Skip
  Name: emb_idx
  Description: vector_similarity GRANULARITY 100000000
  Parts: 1/1
  Granules: 6/24
```

동작합니다. granule을 24개에서 6개로 줄였습니다. 그런데도 쿼리는 **38,462행 중
25,880행** — 테이블의 3분의 2 — 을 읽었습니다. 기본 granularity 1억 때문에 작은
파트에는 인덱스 인스턴스가 거의 만들어지지 않고, 그래서 살아남은 granule 하나가
거대하기 때문입니다.

"ClickHouse는 벡터에 느리다"보다 훨씬 흥미로운 발견입니다. 메커니즘이 눈에
보이고, 10억 행짜리 파트를 상정한 기본값의 튜닝 부작용이며, 이 기능이 이 테스트가
근처에도 못 간 규모를 위해 만들어졌다는 뜻입니다.

### 9. 그래서 선은 어디인가

정직한 답은 이번 실행이 선을 찾지 못했다는 것입니다. **하한**을 찾았습니다.

38,462행에서 답은 명백합니다. 벡터는 Postgres에 있어야 합니다. 1밀리초 대 500
밀리초는 트레이드오프가 아니라 결정입니다. 그것도 1536차원, 임베딩 공간에서 비싼
쪽 끝에서 그렇습니다.

교차점이 실제로 어디인지는 이번 테스트가 고정해 둔 것들에 달려 있습니다 —
ClickHouse 테이블의 파트 수, 인덱스에 준 granularity, 작업집합이 아직 Postgres
인스턴스 메모리에 들어가는지. 이 실험의 흥미로운 버전은 같은 하네스를 100만·
1000만 행에서 돌리며 375ms 완전탐색 기준선과 ClickHouse 수치가 서로를 지나치는
지점을 보는 것입니다.

지금 말할 수 있는 것: **선은 대부분의 사람이 짐작하는 곳보다 한참 위에
있습니다.** 코퍼스가 수만 건 규모라면 pgvector라는 답은 타협이 아닙니다.

### 10. 노트북이 나를 두 번 속인 방식

둘 다 데이터처럼 보이기 때문에 글에 한 문단씩 넣을 만합니다.

**차가운 캐시.** 컨테이너 예행연습에서 HNSW가 쿼리당 5.6ms로 나왔습니다. 워밍 후
수치는 1.79ms입니다. 인덱스를 갓 만들어 페이지 캐시가 비어 있었습니다. 3배
틀렸는데 출력 어디에도 그 사실이 없습니다 — 수치는 진짜이고, 다만 아무도 묻지
않은 질문에 답할 뿐입니다. 워밍 여부를 밝히지 않는 벤치마크는 필요한 것을
말해주지 않는 벤치마크입니다.

**영리하게 인덱스 숨기기.** 인덱스 셋을 비교하려면 하나씩 단독으로 돌려야 하는데,
플래너는 비용으로 고르고 지시를 받지 않습니다. 뻔한 지름길은 원하지 않는 둘의
`pg_index.indisvalid`를 끄는 것입니다.

안 되고, 조용히 실패합니다. PL/pgSQL 내부의 계획 캐싱이 이전 계획을 계속
돌려줘서 모든 방법이 순차 스캔 수치를 보고합니다. 결과는 서로 다른 세 방법이
동일한 recall과 동일한 지연을 갖는, 깔끔해 보이는 표였습니다 — 셋이 정말
동등했다면 실제 결과가 딱 그렇게 생겼을 표입니다.

해법은 멋이 없습니다. 나머지 인덱스를 지우고 다시 만드는 것. 한 사이클에 45초,
그리고 수치는 진짜가 됩니다.

**그리고 같은 실수의 가장 큰 판본**: 이 랩의 첫 회차 전체가 노트북 컨테이너에서
측정됐고, 글은 거기서 결론을 끌어냈습니다. 위의 세 가지 주요 발견 — VectorChord
사용 불가, ClickHouse의 granularity 문제, HNSW가 IVFFlat을 5대 1로 이긴다는 것 —
은 노트북에서 하나도 보이지 않습니다. 그중 둘은 소프트웨어가 아니라 관리형
서비스의 성질입니다.

### 11. 인용할 만한 수치

| | |
|---|---|
| 코퍼스 | dbpedia 100만 건, 1536차원 `text-embedding-3-large`, Parquet 26개, API 키 불필요 |
| 테스트 규모 | 38,462행 (파일 1개) |
| 적재: HF → ClickHouse | 44초 |
| 적재: ClickHouse → Postgres (FDW) | 38.9초 |
| 적재: Parquet → 텍스트 → `COPY` (예행연습) | 분당 약 3,000행 |
| Postgres 테이블 | 322 MB — 힙 16 MB, TOAST 306 MB |
| 완전탐색 | 쿼리당 375.1ms |
| pgvector HNSW | 빌드 68.4초, 300 MB, 0.975 @ 1.45ms |
| pgvector IVFFlat | 빌드 11.4초, 301 MB, 0.975 @ 7.33ms |
| ClickHouse `vector_similarity` | 빌드 29초, 90.6 MiB, 0.985 @ 약 530ms |
| 인덱스가 있는데도 읽은 행 | 38,462 중 25,880 |
| ClickHouse에서 임베딩 압축률 | 239.5 → 215.3 MiB (약 10%) |
| VectorChord | 사용 불가 — `shared_preload_libraries`에 없음 |

### 12. 남은 것

- **100만 행 전체.** 여기 있는 건 방법론입니다. 이 랩이 찾으려는 숫자는 38,000행 위에 있고 하네스는 준비돼 있습니다.
- **교차점이 어디인가.** 같은 쿼리 20개로 100만·1000만을 돌리고 두 곡선을 보는 것.
- **제정신인 granularity의 ClickHouse.** 기본값 1억이 8절의 전부입니다. 작은 테이블에 명시적으로 설정해 보는 건 뻔한 다음 실험이고, 결론을 통째로 바꿀 수도 있습니다.
- **VectorChord, 언젠가 preload된다면.** 그날을 위해 `sql/12-vectorchord.sql`을 남겨뒀습니다. preload하는 컨테이너에서 VectorChord는 0.19ms에 recall 0.965였고 IVFFlat은 같은 recall에 3.77ms가 필요했습니다 — 20배이고, 플랫폼이 열어준다면 제대로 다시 재볼 가치가 있습니다.
- **하이브리드 검색.** `vchord_bm25`와 코퍼스에 이미 있는 본문 텍스트. 같은 이유로 막혀 있습니다.
