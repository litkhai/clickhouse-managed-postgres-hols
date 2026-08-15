# `ui/` — how the dashboard works

[English](#english) | [한국어](#한국어)

---

## English

Implementation notes for the dashboard. What the tabs *show* is in the
[lab README](../README.md#the-dashboard); this file is about what is behind
them — the endpoints, how the verdict is derived, and the handful of decisions
that are not obvious from reading the code straight through.

Two files do the work: `app.py` (stdlib plus `psycopg`, no framework) and
`index.html` (no build step, no bundle). The image is `python:3.12-slim` with
`psycopg[binary]` on top.

### Configuration

Everything arrives as an environment variable; `docker-compose.yml` passes the
lab's `config.env` through unchanged.

| Variable | Default | What it does |
|----------|---------|--------------|
| `LOCAL_SCHEMA` | `bike` | Where the geometry lives. Maps always read this, and it never moves |
| `FOREIGN_SCHEMA` | *(empty)* | Where `sql/40-fdw-clickhouse.sql` imported the foreign tables. Set it and Statistics gains a side switch and Pushdown can run both sides at once |
| `AGG_SCHEMA` | `LOCAL_SCHEMA` | What Statistics falls back to when there are no foreign tables |
| `UI_PORT` | `8080` | Listen port |
| `STATEMENT_TIMEOUT_MS` | `120000` | Server-side ceiling on any one query |
| `PG*` | from `config.env` | Standard libpq variables |

Leaving `FOREIGN_SCHEMA` empty is a supported state, not a broken one. The page
then reports that **there is nothing to push down to** — which is a different
statement from "the pushdown failed", and conflating the two would be the most
misleading thing this page could do.

### Endpoints

| Endpoint | Returns |
|----------|---------|
| `GET /api/catalog` | District list and the default date range |
| `GET /api/dashboard/pulse` | Row counts, table size, lag behind the newest trip, last hour by minute. Index work, ~200 ms — the only thing safe to poll |
| `GET /api/dashboard/series` | The four charts: `daily`, `hourly`, `districts`, `duration`. Scans, so it waits to be asked |
| `GET /api/map/<name>` | GeoJSON from PostGIS: `stations`, `voronoi`, `flows`, `pressure` |
| `GET /api/agg/<name>` | One aggregate: `character`, `corridors`, `districts`, `hourly`, `timeseries`. `?side=auto\|local\|foreign` |
| `GET /api/pushdown/state` | Is `pg_clickhouse` installed, how many foreign servers and tables, which schema will answer |
| `GET /api/pushdown/run` | The same aggregate on **both** sides. `?name=`, `?analyze=1` |
| `GET /api/log` | The session ring buffer and its totals |

Every query response carries the SQL that ran, the elapsed time, and the
verdict. All of them take the same filter query string, so the dashboard and
the aggregates are always counting the same slice.

### The verdict

`analyse()` walks `EXPLAIN (… FORMAT JSON)` as a tree rather than grepping the
text, because the plan is the only honest answer to "did this push down?" —
a fast query proves nothing when Postgres will happily pull 24M rows across the
wire and count them locally.

| Verdict | Condition | Reported as |
|---------|-----------|-------------|
| `no_fdw` | no foreign scan, and no FDW configured | Postgres — nothing to push down to |
| `local` | no foreign scan, but an FDW exists | Postgres — this plan read local tables |
| `pushed` | remote SQL carries the aggregation, and no aggregate node sits above the shallowest foreign scan | **ClickHouse** |
| `partial` | aggregated remotely, then re-aggregated here | Mixed |
| `dragged` | foreign scan selects columns only | Postgres — every row crossed the wire |

Separating `no_fdw` from `local` is the reason for the tree walk. Both look
identical to a check for the string `Remote SQL`, and telling a reader their
query fell back when no FDW was ever configured is worse than saying nothing.

Alongside the verdict each plan yields two numbers that carry the argument:
**rows crossed** (summed over the foreign scans) against **widest node** (the
most rows any single node handled). *3.4M sorted here* versus *15 rows fetched*
is the whole point in one comparison.

`?analyze=1` switches to `EXPLAIN (ANALYZE, VERBOSE, BUFFERS)`, so the counts
are measured rather than the planner's guesses. The query then runs once, not
twice — paying double for the honest option would discourage using it. `COSTS`
stays on either way, because turning it off also removes `Plan Rows`, and the
*estimated* width of a foreign scan is exactly what the unmeasured view is for.

### Four decisions worth knowing

**Client-side parameter binding** (`ClientCursor`). Partly so the SQL the page
displays is the exact text that ran instead of a template with `$1` in it. But
mainly because a parameterised query reaches a foreign table as a generic plan
with placeholders, and a wrapper that cannot see the constants has less to push
down. Literals give it a `WHERE` clause to work with.

**The bucket is whitelisted, not bound.** `date_trunc`'s first argument has to
reach the wrapper as a literal for the rollup to push down. A value that ends
up in SQL as a literal is only safe if it can only ever be one of five known
strings — so it is.

**One timezone constant.** The column is UTC; every date and hour the page
shows or filters on is Korean local time. A KST day *D* is the UTC half-open
range `[D 00:00 − 9h, D+1 00:00 − 9h)`, applied in one place. Seoul has no
daylight saving, so the entire timezone story is `interval '9 hours'`.

**One heavy query at a time**, enforced by a semaphore. At 24M rows a scan is
tens of seconds; a few impatient clicks queue several at once, they evict each
other from a `shared_buffers` smaller than the table, and all of them get
slower — measured here at 18 s alone against 49 s with two others in flight.
It has to be enforced server-side, because aborting a fetch in the browser only
closes the connection: Postgres keeps executing, which is visible in
`pg_stat_activity` after the client has gone.

### Deliberately not production

- The log is a 300-entry ring buffer in memory. A demo aid, not an audit trail.
- The series cache is a dict with a 120 s TTL and a 40-entry cap, evicting in insertion order.
- No authentication. It runs read-only queries against your lab database — keep it on localhost.
- MapLibre GL JS loads from `unpkg.com`, so the map needs internet; everything else works against the database alone.
- Korean by default. `?lang=en`, or the KO/EN switch in the header.

### 📄 License

[MIT](../../../LICENSE) — same as the rest of the repository. MapLibre GL JS is
fetched at run time under its own licence and is not vendored here.

---

## 한국어

대시보드 구현 노트입니다. 각 탭이 **무엇을 보여주는지**는
[랩 README](../README.md#대시보드)에 있고, 이 문서는 그 뒤쪽 — 엔드포인트,
판정을 끌어내는 방식, 그리고 코드를 순서대로 읽어서는 잘 드러나지 않는 몇 가지
결정 — 을 다룹니다.

일하는 파일은 둘입니다. `app.py`(표준 라이브러리 + `psycopg`, 프레임워크 없음)와
`index.html`(빌드 단계 없음, 번들 없음). 이미지는 `python:3.12-slim` 위에
`psycopg[binary]`가 전부입니다.

### 설정

모두 환경변수로 들어옵니다. `docker-compose.yml`이 랩의 `config.env`를 그대로
넘깁니다.

| 변수 | 기본값 | 역할 |
|------|--------|------|
| `LOCAL_SCHEMA` | `bike` | 지오메트리가 사는 곳. 지도는 항상 여기를 읽고, 여기서 옮겨가지 않습니다 |
| `FOREIGN_SCHEMA` | *(비어 있음)* | `sql/40-fdw-clickhouse.sql`이 외래 테이블을 가져다 둔 곳. 설정하면 통계 탭에 쪽 전환이 생기고 푸시다운 탭이 양쪽을 동시에 실행합니다 |
| `AGG_SCHEMA` | `LOCAL_SCHEMA` | 외래 테이블이 없을 때 통계 탭이 되돌아갈 스키마 |
| `UI_PORT` | `8080` | 리슨 포트 |
| `STATEMENT_TIMEOUT_MS` | `120000` | 단일 쿼리의 서버 측 상한 |
| `PG*` | `config.env`에서 | 표준 libpq 변수 |

`FOREIGN_SCHEMA`를 비워두는 것은 고장이 아니라 지원되는 상태입니다. 그때
페이지는 **내려보낼 대상이 없다**고 표시합니다 — "푸시다운이 실패했다"와는 다른
진술이고, 이 둘을 뭉뚱그리는 것이야말로 이 페이지가 할 수 있는 가장 오해를
부르는 일입니다.

### 엔드포인트

| 엔드포인트 | 반환 |
|------------|------|
| `GET /api/catalog` | 자치구 목록과 기본 날짜 범위 |
| `GET /api/dashboard/pulse` | 행 수, 테이블 크기, 최신 대여로부터의 지연, 최근 1시간의 분당 추이. 인덱스 작업이라 약 200 ms — 폴링해도 되는 유일한 항목 |
| `GET /api/dashboard/series` | 차트 4개: `daily`, `hourly`, `districts`, `duration`. 스캔이므로 요청을 기다립니다 |
| `GET /api/map/<name>` | PostGIS GeoJSON: `stations`, `voronoi`, `flows`, `pressure` |
| `GET /api/agg/<name>` | 집계 하나: `character`, `corridors`, `districts`, `hourly`, `timeseries`. `?side=auto\|local\|foreign` |
| `GET /api/pushdown/state` | `pg_clickhouse` 설치 여부, 외래 서버·테이블 수, 어느 스키마가 답할지 |
| `GET /api/pushdown/run` | 같은 집계를 **양쪽**에서. `?name=`, `?analyze=1` |
| `GET /api/log` | 세션 링 버퍼와 합계 |

모든 쿼리 응답은 실행된 SQL, 소요 시간, 판정을 함께 싣습니다. 전부 같은 필터
쿼리스트링을 받으므로, 대시보드와 집계가 세는 구간은 항상 같습니다.

### 판정

`analyse()`는 `EXPLAIN (… FORMAT JSON)`을 텍스트로 grep하지 않고 **트리로
순회**합니다. "이게 푸시다운됐나?"에 대한 정직한 답은 실행 계획에만 있기
때문입니다 — 빠르다는 것은 아무 증거가 되지 않습니다. Postgres는 2,400만 행을
네트워크로 다 끌어와 로컬에서 세는 일을 아무렇지 않게 합니다.

| 판정 | 조건 | 표시 |
|------|------|------|
| `no_fdw` | 외래 스캔 없음, FDW도 구성 안 됨 | Postgres — 내려보낼 대상이 없음 |
| `local` | 외래 스캔 없음, 그러나 FDW는 있음 | Postgres — 이 계획은 로컬 테이블을 읽음 |
| `pushed` | 원격 SQL이 집계를 포함하고, 가장 얕은 외래 스캔 위에 집계 노드가 없음 | **ClickHouse** |
| `partial` | 원격에서 집계한 뒤 여기서 재집계 | 혼합 |
| `dragged` | 외래 스캔이 컬럼만 select | Postgres — 모든 행이 네트워크를 건넘 |

`no_fdw`와 `local`을 나누는 것이 트리 순회의 이유입니다. `Remote SQL` 문자열만
확인해서는 둘이 똑같아 보이는데, FDW를 구성한 적도 없는 사람에게 "쿼리가
폴백됐다"고 말하는 건 아무 말도 안 하느니만 못합니다.

판정과 함께 계획에서 뽑는 두 숫자가 논거를 만듭니다. **건너간 행 수**(외래
스캔 합계) 대 **가장 넓은 노드**(단일 노드가 처리한 최대 행 수). *여기서 340만
행 정렬* 대 *15행 가져옴* — 이 한 쌍이 요점 전부입니다.

`?analyze=1`이면 `EXPLAIN (ANALYZE, VERBOSE, BUFFERS)`로 바뀌어 추정치가 아닌
실측치가 나옵니다. 이때 쿼리는 두 번이 아니라 한 번만 돕니다 — 정직한 선택지에
두 배를 물리면 아무도 쓰지 않을 테니까요. `COSTS`는 어느 쪽이든 켜둡니다. 끄면
`Plan Rows`까지 사라지는데, 외래 스캔의 **추정** 폭이야말로 실측 없는 화면의
존재 이유입니다.

### 알아둘 만한 결정 네 가지

**클라이언트 측 파라미터 바인딩**(`ClientCursor`). 하나는 페이지에 표시되는
SQL이 `$1`이 박힌 템플릿이 아니라 실제로 실행된 텍스트 그대로가 되도록 하기
위해서입니다. 하지만 더 중요한 이유는, 파라미터화된 쿼리는 외래 테이블에
플레이스홀더가 든 일반 계획으로 도착하고, 상수를 볼 수 없는 래퍼는 내려보낼
것이 그만큼 줄어들기 때문입니다. 리터럴이어야 `WHERE` 절을 넘길 수 있습니다.

**버킷은 바인딩이 아니라 화이트리스트.** `date_trunc`의 첫 인자가 래퍼에
리터럴로 도착해야 롤업이 푸시다운됩니다. SQL에 리터럴로 들어가는 값은 미리
정해진 다섯 문자열 중 하나일 수밖에 없을 때만 안전하고, 그래서 그렇게 했습니다.

**시간대 상수 하나.** 컬럼은 UTC이고, 페이지가 보여주거나 필터에 쓰는 모든
날짜와 시각은 한국 현지 시각입니다. KST의 하루 *D*는 UTC 반열린 구간
`[D 00:00 − 9h, D+1 00:00 − 9h)`이며, 이 변환을 한 곳에서만 합니다. 서울은
서머타임이 없어서 시간대 이야기 전체가 `interval '9 hours'` 하나로 끝납니다.

**무거운 쿼리는 한 번에 하나**, 세마포어로 강제합니다. 2,400만 행 스캔은 수십
초입니다. 조급한 클릭 몇 번이 여러 개를 동시에 띄우면 테이블보다 작은
`shared_buffers`에서 서로를 밀어내며 전부 느려집니다 — 여기서 실측한 값이 혼자
18초, 다른 둘과 함께 49초입니다. 이건 서버 쪽에서 막아야 합니다. 브라우저에서
요청을 취소해도 연결만 닫힐 뿐 Postgres는 계속 실행하며, 클라이언트가 끊긴 뒤
`pg_stat_activity`에서 그대로 보입니다.

### 의도적으로 프로덕션이 아닌 부분

- 로그는 메모리의 300개짜리 링 버퍼입니다. 감사 기록이 아니라 데모 보조 장치입니다.
- 시리즈 캐시는 TTL 120초, 최대 40개인 dict이며 삽입 순서로 밀어냅니다.
- 인증이 없습니다. 랩 데이터베이스에 읽기 전용 쿼리를 돌리므로 localhost에 두세요.
- MapLibre GL JS를 `unpkg.com`에서 받으므로 지도에는 인터넷이 필요합니다. 나머지는 데이터베이스만으로 동작합니다.
- 기본 언어는 한국어입니다. `?lang=en` 또는 헤더의 KO/EN 전환을 쓰세요.

### 📄 라이선스

[MIT](../../../LICENSE) — 저장소 전체와 동일합니다. MapLibre GL JS는 실행 시점에
각자의 라이선스로 내려받으며 여기에 포함하지 않습니다.
