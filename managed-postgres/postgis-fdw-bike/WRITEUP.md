# How this demo was built

Source material for a write-up: what the demo argues, where the data came from,
which decisions were forced by the platform, and how the lab is put together.
Numbers here were measured on a live ClickHouse Managed Postgres service in
`ap-northeast-2`, August 2026.

[English](#english) | [한국어](#한국어)

---

## English

### 1. The argument

Analytics teams are told to pick: keep the operational database and accept slow
aggregates, or move to a column store and lose everything the operational
database was good at. For spatial workloads that choice is unusually painful,
because the thing you lose — PostGIS — has no column-store equivalent worth the
name.

The demo argues you do not have to pick. Put the geography in Postgres, put the
counting in ClickHouse, and connect them with a foreign data wrapper. Each side
does what it is good at, and the boundary between them turns out to be a single
integer column.

### 2. Choosing the data

The requirements were narrow:

- A **small, nearly static set of geometries** — the PostGIS side.
- A **large, append-only fact table** referencing those geometries — the
  ClickHouse side.
- The two joinable **without geometry crossing the boundary**.
- Openly licensed, since the repository is public.
- Downloadable without an account, so the lab is reproducible.

Seoul's public bike system fits almost exactly. Two datasets from
서울 열린데이터광장:

| Dataset | ID | Shape |
|---|---|---|
| 공공자전거 대여소 정보 | `OA-13252` | 2,789 stations with lat/lon — the geometry |
| 공공자전거 대여이력 정보 | `OA-15182` | one row per trip, ~1.6M per month — the facts |

Both are **공공누리 제1유형**: attribution, commercial use and modification
allowed. No API key, no account.

What made it the right choice is the trip record itself. Each row carries a
start station and an end station as **integer ids** — origin–destination data,
not just points on a map. So the join key is an integer, and no geometry ever
has to reach the aggregating side. That is the whole architecture, handed over
by the data model.

**Getting the files.** The portal serves them over a plain POST to
`datafile.seoul.go.kr`, keyed by an internal per-file sequence number plus a
per-dataset `infSeq`. Neither is discoverable through an API, so they are pinned
in `scripts/fetch-data.sh`. Worth knowing: a wrong `infSeq` does not error — it
serves **a different dataset's file**. The script checks the filename in the
response and refuses anything unexpected. The CSVs are CP949, not UTF-8, and
the station master is an `.xlsx` with a five-row merged header.

### 3. What the platform gave us

ClickHouse Managed Postgres, checked on the running service rather than assumed:

```
PostgreSQL 18.4 (aarch64)          TLS 1.3 enforced, plaintext refused
postgis 3.6.4                      also h3 4.2.3, h3_postgis, postgis_raster,
                                   postgis_topology, postgis_sfcgal
pg_clickhouse 0.3                  the FDW — available, not installed by default
pg_cron 1.6                        already in shared_preload_libraries
pg_stat_ch 0.3                     installed by default
wal_level = logical                out of the box; no restart to enable CDC
101 extensions available in total
```

Three of these shaped the demo:

- **PostGIS is a real 3.6.4**, not a cut-down build — Voronoi, DBSCAN and
  geography-typed distance all work.
- **`wal_level` is already `logical`**, so ClickPipes needs no configuration
  change on the Postgres side.
- **`pg_cron` is preloaded**, which is what makes a server-side generator
  possible. The demo keeps running with the laptop closed.

### 4. The one decision worth arguing about: UTC

The trip data is published in Korean local time. The column is
`timestamp without time zone`. Nothing anywhere records which zone the numbers
are in.

That is survivable inside Postgres and dangerous the moment ClickHouse is
involved, because **ClickHouse attaches a timezone to `DateTime`** and Postgres
does not. The same wall-clock number means two different instants on the two
sides. Hourly aggregates come out shifted by nine hours, and nothing errors.

So the table stores **UTC**:

- `scripts/shift-to-utc.sh` converted the existing rows once.
- `scripts/load-trips.sh` subtracts nine hours on the way in.
- Both generators stamp UTC.

Korea has no daylight saving, so the offset is a constant nine hours and the
conversion is a subtraction rather than a zone-aware cast.

The visible consequence: the weekday commute peaks now sit at **23:00 and 09:00
UTC**. Queries convert back to Seoul time where a reader would otherwise
misread the number, and the schema says UTC in a comment on the column, because
the type cannot.

**The conversion had to be batched.** One `UPDATE` over 23.8M rows rewrites
every tuple in a single transaction: the table roughly doubles before autovacuum
can reclaim anything, and around 20 GB of WAL is pinned until commit. Walking
the primary key in 250k-row batches keeps dead tuples collectable and WAL
drainable as it goes — 689 seconds for 23,870,900 rows. Progress is bookmarked
in a table rather than inferred, because a converted row is indistinguishable
from one that never needed converting; resuming by timestamp would silently
shift some rows twice.

### 5. Building a dataset that behaves like the real one

One real month is 1.6M trips. A demo wants more, and it wants *today* to have
data. Three pieces:

**Real history.** January 2026, loaded as published: 1,646,600 trips.

**Backfill.** `scripts/backfill-trips.sh` asks the database which days between
the first loaded trip and yesterday have no rows, and writes only those. 195
days were missing; at real volume that is 22.2M trips.

**Live feed.** `sql/30-generator-in-db.sql` installs a procedure and a pg_cron
job that inserts, every minute, however many trips this hour of this weekday
calls for.

Total: **24,037,356 trips across 228 days**, 7.1 GB.

#### How the synthetic trips are made, and why

The tempting approach is to sample each column from its own distribution. It
produces a table where every histogram is right and every relationship is gone.
Here that would be fatal: morning trips run to subway stations and last eight
minutes, Sunday afternoon trips run along the river and last forty, rider age
shifts with both, and the OD matrix is extremely skewed — a handful of stations
near river crossings and office parks carry a disproportionate share. Sample
independently and the OD matrix goes uniform, which flattens exactly the
aggregates the demo exists to show.

So a generated trip is **a real trip with a new timestamp**, drawn from the pool
of real trips that started in the *same hour of the same kind of day*. Hour of
day stays tied to origin, destination, duration and rider. Only volume and
timestamps are synthetic; duration gets ±20% jitter, and distance scales with it
so the implied speed stays plausible.

Measured against the real month:

| | real (Jan) | generated |
|---|---|---|
| share of weekday trips at the morning peak | 28.16% | 28.20% |
| share at the evening peak | 26.55% | 26.49% |
| mean duration | 17.1 min | 17.0 min |
| mean distance | 1,724 m | 1,718 m |
| round trips | 8.6% | 8.7% |

**What is measured and what is assumed.** The hourly shape, the weekday/weekend
ratio (60,388 vs 37,893 trips per day) and the trip pool are all measured. The
month-to-month scale is not — only one month was loaded. The portal's published
monthly file sizes stand in for trip counts (280, 307, 501, 674, 690, 716 MB for
2026-01 to 06, so June is 2.56× January), and July onward is extrapolated
because those files are not published yet. `--explain` names the guessed months
rather than hiding them.

**Arrivals are drawn from a Poisson.** A fixed rate makes every window return
the identical count, and a live feed that ticks like a metronome is obviously
fake at a glance.

### 6. Replication

ClickPipes replicates `bike.trips` and `bike.stations` into ClickHouse.

**A primary key is required.** ClickPipes refuses a table without a replica
identity: *"cannot be replicated because they don't have a valid replica
identity"*. The trip data has no natural key — `bike_id` with both timestamps
and both station ids still leaves 96 rows non-unique, and those are genuinely
distinct trips that differ only in the distance recorded. A surrogate
`bigint GENERATED ALWAYS AS IDENTITY` was added; 7.7 seconds over 1.64M rows.
`REPLICA IDENTITY FULL` would also clear the error, but the key additionally
gives ClickHouse something sensible to order and deduplicate on.

**Only two tables should replicate.** The generator's working tables — the
sample pool, the hour weights, the seasonal factors — live in a separate
`bikegen` schema, so a publication declared `FOR ALL TABLES` cannot sweep them
into ClickHouse. The `bike` schema holds exactly `trips` and `stations`.

**Two things to monitor.** `confirmed_flush_lsn` advances in steps, not
continuously, because the consumer confirms once a batch has landed downstream —
watching it for five seconds and concluding it has stalled is a mistake. And an
**inactive slot retains WAL indefinitely**: one bulk load arriving as a single
22M-row transaction was enough to disconnect the consumer, after which the slot
sat holding 13 GB. `SELECT count(*) FROM pg_replication_slots WHERE NOT active`
belongs in whatever you monitor. Loading in smaller transactions avoids the
situation entirely.

### 7. The query split

Ten queries, in two files, chosen so the boundary is visible.

**`sql/10-spatial-postgres.sql` — cannot move.** Voronoi service areas per
station clipped to the network hull; five nearest neighbours per station through
the GiST index and the `<->` operator; DBSCAN clusters that straddle
administrative boundaries; detour factor comparing recorded distance to the
geodesic; net flow per district with its mean bearing.

That last one is worth a paragraph in any write-up. Bearings are circular, so
averaging them arithmetically makes 350° and 10° come out as 180° — the exact
opposite of the truth. Because flows are roughly symmetric, the naive version
reported a confident "south" for all 25 districts. Summing unit vectors and
taking `atan2` gives the real mean, and the length of the resultant says whether
there is a dominant direction at all: two districts turn out to have none, and
the query says so instead of inventing one.

**`sql/20-aggregate-pushdown.sql` — should move.** Which stations are commuter
stations rather than leisure stations; the heaviest corridors end to end;
where rebalancing vans are actually needed; how each district rides; when each
district wakes up.

The instinct is to keep the station join in Postgres and let only the counting
travel. That is wrong here, and the documentation is explicit:

> *pg_clickhouse also pushes down JOINs to tables that are from the same remote
> server.*
>
> *Joining with a local table will generate less efficient queries without
> careful tuning.*

Since ClickPipes replicates `stations` too, naming a station or grouping by
district is remote work like everything else. **What breaks pushdown is mixing
in a local table, not joining as such.** Exactly one query needs that — the
corridor query calls `ST_Distance`, which has no remote form — and it is marked
as the boundary case.

Both files select their schema through `search_path`, so the same file runs
against local or foreign tables and the plans can be compared directly:

```bash
./scripts/psql.sh -f /sql/20-aggregate-pushdown.sql                    # local
./scripts/psql.sh -v target=ch_bike -f /sql/20-aggregate-pushdown.sql  # remote
```

**Verifying pushdown.** `EXPLAIN (VERBOSE)` prints the SQL the wrapper intends
to send, and that text is the answer:

```
Foreign Scan
  Remote SQL: SELECT a, count(*) FROM t GROUP BY a     <- pushed down

Aggregate
  -> Foreign Scan
       Remote SQL: SELECT a FROM t                     <- not pushed down
```

The second form means every row crossed the network to be counted locally,
which is slower than never moving the table. Nothing warns about it.
`scripts/explain-pushdown.sh` reads the plan and reports the verdict per query.

### 8. Lab structure

```
sql/01-schema.sql             stations (PostGIS) + trips, UTC noted on the column
sql/02-verify.sql             what loaded, and where the data disagrees with itself
sql/10-spatial-postgres.sql   five queries that stay
sql/20-aggregate-pushdown.sql five that travel
sql/30-generator-in-db.sql    pg_cron + procedure, model tables in bikegen

scripts/fetch-data.sh         download, with filename verification
scripts/load-stations.sh      xlsx -> PostGIS, geometry + GiST index
scripts/load-trips.sh         CP949 -> UTF-8, KST -> UTC, staged then cast
scripts/backfill-trips.sh     fill missing days
scripts/catch-up.sh           fill the hours since the newest trip
scripts/shift-to-utc.sh       one-off conversion, primary-key batches
scripts/generate-trips.sh     client-side live feed
scripts/explain-pushdown.sh   did it push down?
scripts/psql.sh               psql in a container
```

Everything runs `psql` in a container, so the lab needs nothing installed. The
connection host embeds the service name and id, so all output masks it.
Credentials live in a gitignored `config.env`.

Run order:

```bash
ln -s ../provisioning/config.env config.env
./scripts/fetch-data.sh
./scripts/load-stations.sh
./scripts/load-trips.sh
./scripts/backfill-trips.sh
./scripts/catch-up.sh
./scripts/psql.sh -f /sql/30-generator-in-db.sql
./scripts/psql.sh -c "SELECT bike.generator_schedule('1 minute')"
```

### 9. Numbers worth quoting

| | |
|---|---|
| Stations | 2,789 across 25 districts |
| Trips | 24,037,356 over 228 days |
| Table size | 7.1 GB (256 bytes per row including indexes) |
| WAL generated | 811 bytes per row |
| Real month load | 1.64M rows in 53s via COPY |
| UTC conversion | 23.87M rows in 689s, 250k-row batches |
| Backfill | 22.2M rows generated and loaded |
| Add primary key | 7.7s over 1.64M rows |
| Live feed | ~480 trips per 5 minutes at an off-peak hour |

---

## 한국어

### 1. 주장

분석 팀은 보통 둘 중 하나를 고르라는 말을 듣습니다. 운영 DB를 유지하고 느린
집계를 감수하거나, 컬럼 스토어로 옮기고 운영 DB가 잘하던 것을 포기하거나.
공간 워크로드에서는 이 선택이 특히 아픈데, 포기하게 되는 것이 **PostGIS**이고
컬럼 스토어 쪽에 그에 견줄 대체물이 없기 때문입니다.

이 데모의 주장은 고를 필요가 없다는 것입니다. 지리는 Postgres에, 집계는
ClickHouse에 두고 FDW로 잇습니다. 각자 잘하는 일만 하고, 그 경계는 결국
**정수 컬럼 하나**로 드러납니다.

### 2. 데이터 선정

요구조건은 좁았습니다.

- **작고 거의 변하지 않는 지오메트리 집합** — PostGIS 쪽
- 그 지오메트리를 참조하는 **크고 append-only인 팩트 테이블** — ClickHouse 쪽
- 둘이 **지오메트리를 넘기지 않고** 조인 가능할 것
- 저장소가 공개이므로 오픈 라이선스일 것
- 계정 없이 내려받을 수 있어 재현 가능할 것

서울 공공자전거가 거의 정확히 맞았습니다. 서울 열린데이터광장의 두 데이터셋:

| 데이터셋 | ID | 형태 |
|---|---|---|
| 공공자전거 대여소 정보 | `OA-13252` | 위경도 포함 2,789개 대여소 — 지오메트리 |
| 공공자전거 대여이력 정보 | `OA-15182` | 대여 1건당 1행, 월 약 164만 — 팩트 |

둘 다 **공공누리 제1유형**(출처표시, 상업적 이용·변경 가능)이고 API 키도 계정도
필요 없습니다.

결정적이었던 건 대여이력의 구조입니다. 각 행이 출발·도착 대여소를 **정수 ID**로
갖습니다 — 지도 위의 점이 아니라 OD 데이터입니다. 따라서 조인 키가 정수이고,
지오메트리가 집계하는 쪽으로 건너갈 일이 없습니다. 아키텍처가 데이터 모델에서
그대로 떨어집니다.

**파일 받기.** 포털은 `datafile.seoul.go.kr`에 평범한 POST로 파일을 내주는데,
파일별 내부 sequence 번호와 데이터셋별 `infSeq`로 식별합니다. 둘 다 API로 조회할
수단이 없어 `scripts/fetch-data.sh`에 값을 박아두었습니다. 알아둘 점:
`infSeq`가 틀리면 오류가 나지 않고 **다른 데이터셋의 파일이 내려옵니다.**
스크립트가 응답의 파일명을 검사해 예상과 다르면 거부합니다. CSV 인코딩은 CP949,
대여소 마스터는 헤더가 5행 병합된 `.xlsx`입니다.

### 3. 플랫폼이 제공한 것

ClickHouse Managed Postgres에서 가정이 아니라 실제로 확인한 값들:

```
PostgreSQL 18.4 (aarch64)          TLS 1.3 강제, 평문 거부
postgis 3.6.4                      h3 4.2.3, h3_postgis, postgis_raster,
                                   postgis_topology, postgis_sfcgal 도 함께
pg_clickhouse 0.3                  FDW — 사용 가능, 기본 미설치
pg_cron 1.6                        이미 shared_preload_libraries 에 등록
pg_stat_ch 0.3                     기본 설치
wal_level = logical                기본값 — CDC 위해 재시작 불필요
사용 가능 확장 총 101개
```

이 중 셋이 데모의 형태를 결정했습니다.

- **PostGIS가 축소판이 아닌 정식 3.6.4** — Voronoi, DBSCAN, geography 거리 모두 동작
- **`wal_level`이 이미 `logical`** — ClickPipes 붙이는 데 Postgres 쪽 설정 변경 불필요
- **`pg_cron`이 프리로드됨** — 서버 사이드 생성기가 가능해진 이유. 노트북을 닫아도 데모가 계속 돕니다

### 4. 논쟁할 만한 결정 하나: UTC

대여이력은 한국 현지 시각으로 발행됩니다. 컬럼은
`timestamp without time zone`입니다. 그 숫자가 어느 시간대인지 어디에도 기록돼
있지 않습니다.

Postgres 안에서는 견딜 만하지만 ClickHouse가 끼는 순간 위험해집니다.
**ClickHouse는 `DateTime`에 시간대를 붙이고** Postgres는 붙이지 않기 때문입니다.
같은 벽시계 숫자가 양쪽에서 다른 순간을 뜻하게 됩니다. 시간대별 집계가 9시간
어긋나고, **아무 오류도 나지 않습니다.**

그래서 테이블은 **UTC**로 저장합니다.

- `scripts/shift-to-utc.sh`가 기존 행을 한 번 변환
- `scripts/load-trips.sh`가 적재 시 9시간 차감
- 두 생성기 모두 UTC로 기록

한국은 서머타임이 없어 오프셋이 상수 9시간이므로, 시간대 인식 캐스팅이 아니라
뺄셈으로 처리했습니다.

눈에 보이는 결과: 평일 출퇴근 피크가 **23:00·09:00 UTC**로 옮겨갑니다. 쿼리는
읽는 사람이 오해할 지점에서 서울 시각으로 되돌려 보여주고, 타입이 말해줄 수 없는
사실이라 스키마 주석에 UTC라고 적었습니다.

**변환은 나눠야 했습니다.** 23.8M 행에 대한 단일 `UPDATE`는 모든 튜플을 한
트랜잭션에서 재작성합니다. autovacuum이 회수하기 전에 테이블이 약 두 배가 되고,
커밋 전까지 WAL 20 GB가 묶입니다. PK를 25만 행씩 걸어가면 죽은 튜플이 계속
회수되고 WAL도 흘러갑니다 — 23,870,900행에 689초. 진행 상황은 추론이 아니라
테이블에 기록합니다. 변환된 행은 변환이 필요 없던 행과 구별되지 않아서,
타임스탬프로 재개하면 일부를 **조용히 두 번 밀게** 됩니다.

### 5. 실제처럼 움직이는 데이터셋 만들기

실제 한 달은 164만 건입니다. 데모는 더 많이 필요하고, **오늘** 데이터가 있어야
합니다. 세 조각으로 나눴습니다.

**실제 이력.** 2026년 1월, 발행된 그대로 1,646,600건.

**백필.** `scripts/backfill-trips.sh`가 첫 적재일부터 어제까지 중 행이 없는
날짜를 DB에 물어 그 날짜만 씁니다. 195일이 비어 있었고, 실물량으로 2,220만 건.

**실시간 피드.** `sql/30-generator-in-db.sql`이 프로시저와 pg_cron 잡을 설치해,
매분 지금 이 요일·이 시각에 맞는 만큼 삽입합니다.

합계: **228일에 걸쳐 24,037,356건**, 7.1 GB.

#### 합성 대여를 만드는 방식과 그 이유

컬럼마다 자기 분포에서 뽑는 방식이 끌리지만, 그러면 히스토그램은 다 맞고 관계는
전부 사라진 테이블이 나옵니다. 여기서는 치명적입니다. 아침 대여는 지하철역으로
8분, 일요일 오후는 강변으로 40분, 연령대도 그에 따라 달라지고, OD 행렬은 편중이
매우 심합니다 — 한강 다리 근처와 오피스 단지 몇 곳이 큰 비중을 차지합니다.
독립적으로 뽑으면 OD 행렬이 균등해지고, 이 데모가 보여주려는 집계가 바로 그
지점에서 밋밋해집니다.

그래서 생성된 대여는 **실제 대여에 새 타임스탬프를 붙인 것**이며, *같은 종류의
요일·같은 시각*에 시작된 실제 대여 풀에서 뽑습니다. 시간대가 출발지·도착지·
소요시간·이용자와 계속 묶여 있습니다. 합성인 것은 물량과 타임스탬프뿐이고,
소요시간에 ±20% 흔들림을 주되 거리도 같은 비율로 조정해 함의 속도가 그럴듯하게
유지되도록 했습니다.

실제 한 달과 비교:

| | 실제(1월) | 생성 |
|---|---|---|
| 평일 아침 피크 비중 | 28.16% | 28.20% |
| 저녁 피크 비중 | 26.55% | 26.49% |
| 평균 소요시간 | 17.1분 | 17.0분 |
| 평균 거리 | 1,724 m | 1,718 m |
| 왕복 비율 | 8.6% | 8.7% |

**측정한 것과 가정한 것.** 시간대 형태, 평일/주말 비(일 60,388건 대 37,893건),
대여 풀은 모두 측정값입니다. 월별 규모는 아닙니다 — 한 달만 적재했으니까요.
포털에 공개된 월별 파일 크기를 대여 건수의 대리 지표로 썼고(2026-01~06: 280,
307, 501, 674, 690, 716 MB, 즉 6월이 1월의 2.56배), 7월 이후는 파일이 아직
없어 외삽입니다. `--explain`이 추정 구간을 숨기지 않고 표시합니다.

**도착은 포아송에서 뽑습니다.** 고정 속도면 모든 창이 똑같은 수를 반환하고,
메트로놈처럼 뛰는 실시간 피드는 한눈에 가짜로 보입니다.

### 6. 복제

ClickPipes가 `bike.trips`와 `bike.stations`를 ClickHouse로 복제합니다.

**기본키가 필수입니다.** replica identity가 없는 테이블을 ClickPipes가
거부합니다 — *"cannot be replicated because they don't have a valid replica
identity"*. 이 데이터에는 자연키가 없습니다. `bike_id`와 양쪽 타임스탬프,
양쪽 대여소번호를 모두 합쳐도 96행이 겹치는데, 그건 중복이 아니라 기록된 거리만
다른 별개의 대여입니다. 대리키 `bigint GENERATED ALWAYS AS IDENTITY`를
추가했고 164만 행에 7.7초 걸렸습니다. `REPLICA IDENTITY FULL`로도 오류는
없앨 수 있지만, 키가 있으면 ClickHouse 쪽 정렬·중복제거 기준도 함께 생깁니다.

**복제 대상은 두 테이블뿐이어야 합니다.** 생성기의 작업 테이블(표본 풀, 시간대
가중치, 계절 계수)은 별도 `bikegen` 스키마에 둬서, `FOR ALL TABLES` 퍼블리케이션
이라도 딸려가지 않습니다. `bike` 스키마에는 `trips`와 `stations`만 있습니다.

**지켜볼 것 두 가지.** `confirmed_flush_lsn`은 연속이 아니라 **계단식**으로
전진합니다. 소비자가 배치를 하류에 넣은 뒤 확인하기 때문이라, 5초 보고 멈췄다고
판단하면 틀립니다. 그리고 **비활성 슬롯은 WAL을 무한정 붙듭니다.** 대량 적재가
2,200만 행 단일 트랜잭션으로 도착하자 소비자가 떨어져 나갔고, 그 뒤 슬롯이
13 GB를 쥐고 있었습니다. `SELECT count(*) FROM pg_replication_slots WHERE NOT
active`를 모니터링에 넣으세요. 더 작은 트랜잭션으로 적재하면 애초에 생기지
않습니다.

### 7. 쿼리 분리

경계가 보이도록 고른 쿼리 10개, 두 파일.

**`sql/10-spatial-postgres.sql` — 옮길 수 없는 것.** 대여소별 Voronoi 세력권을
네트워크 껍질로 클리핑, GiST 인덱스와 `<->` 연산자로 대여소별 최근접 5개,
행정경계를 가로지르는 DBSCAN 군집, 기록 거리와 측지선을 비교한 우회율,
자치구별 순유출입과 평균 방위.

마지막 것은 글에 한 문단 쓸 만합니다. 방위각은 순환값이라 산술평균하면 350°와
10°의 평균이 180°가 됩니다 — 정확히 반대 방향입니다. 흐름이 대체로 대칭이라,
소박한 버전은 25개 자치구 전부에 대해 자신 있게 "남쪽"이라고 답했습니다. 단위
벡터를 더해 `atan2`를 취하면 진짜 평균이 나오고, 합벡터의 길이가 애초에 지배적인
방향이 있는지를 말해줍니다. 두 자치구는 방향이 없는 것으로 나왔고, 쿼리가
지어내는 대신 그렇다고 표시합니다.

**`sql/20-aggregate-pushdown.sql` — 옮겨야 하는 것.** 어느 대여소가 출퇴근용이고
어느 쪽이 여가용인지, 가장 무거운 회랑, 재배치 밴이 실제로 필요한 곳, 자치구별
이용 양상, 자치구가 깨어나는 시각.

대여소 조인은 Postgres에 남기고 집계만 보내고 싶어지지만, 여기서는 틀립니다.
문서가 명시합니다.

> *pg_clickhouse also pushes down JOINs to tables that are from the same remote
> server.*
>
> *Joining with a local table will generate less efficient queries without
> careful tuning.*

ClickPipes가 `stations`도 복제하므로, 대여소 이름을 붙이거나 자치구로 묶는 것도
다른 작업과 같은 원격 작업입니다. **푸시다운을 깨는 건 조인 자체가 아니라 로컬
테이블을 섞는 것입니다.** 그게 필요한 쿼리는 정확히 하나 — 회랑 쿼리가
`ST_Distance`를 쓰는데 원격 대응물이 없습니다 — 이고 경계 사례로 표시했습니다.

두 파일 모두 `search_path`로 스키마를 고르므로, 같은 파일을 로컬/외래 양쪽에
겨눠 플랜을 직접 비교할 수 있습니다.

```bash
./scripts/psql.sh -f /sql/20-aggregate-pushdown.sql                    # 로컬
./scripts/psql.sh -v target=ch_bike -f /sql/20-aggregate-pushdown.sql  # 원격
```

**푸시다운 확인.** `EXPLAIN (VERBOSE)`가 래퍼가 보낼 SQL을 출력하고, 그 텍스트가
답입니다.

```
Foreign Scan
  Remote SQL: SELECT a, count(*) FROM t GROUP BY a     <- 푸시다운됨

Aggregate
  -> Foreign Scan
       Remote SQL: SELECT a FROM t                     <- 안 됨
```

두 번째는 모든 행이 네트워크를 건너와 로컬에서 세어진 것이고, 테이블을 옮기지
않느니만 못합니다. **아무 경고도 없습니다.**
`scripts/explain-pushdown.sh`가 플랜을 읽어 쿼리별로 판정합니다.

### 8. 실습 구성

```
sql/01-schema.sql             stations(PostGIS) + trips, 컬럼 주석에 UTC 명시
sql/02-verify.sql             무엇이 적재됐고 데이터가 어디서 모순되는지
sql/10-spatial-postgres.sql   남아야 하는 쿼리 5개
sql/20-aggregate-pushdown.sql 옮겨야 하는 쿼리 5개
sql/30-generator-in-db.sql    pg_cron + 프로시저, 모델 테이블은 bikegen

scripts/fetch-data.sh         다운로드, 파일명 검증 포함
scripts/load-stations.sh      xlsx → PostGIS, 지오메트리 + GiST 인덱스
scripts/load-trips.sh         CP949 → UTF-8, KST → UTC, 스테이징 후 캐스팅
scripts/backfill-trips.sh     빠진 날짜 채우기
scripts/catch-up.sh           최신 대여 이후 시각 단위 공백 채우기
scripts/shift-to-utc.sh       1회 변환, PK 구간 단위
scripts/generate-trips.sh     클라이언트 측 실시간 피드
scripts/explain-pushdown.sh   푸시다운 됐나?
scripts/psql.sh               컨테이너 psql
```

모두 `psql`을 컨테이너로 실행하므로 설치할 것이 없습니다. 접속 호스트에 서비스
이름과 id가 들어 있어 모든 출력에서 마스킹합니다. 자격증명은 gitignore된
`config.env`에 둡니다.

실행 순서:

```bash
ln -s ../provisioning/config.env config.env
./scripts/fetch-data.sh
./scripts/load-stations.sh
./scripts/load-trips.sh
./scripts/backfill-trips.sh
./scripts/catch-up.sh
./scripts/psql.sh -f /sql/30-generator-in-db.sql
./scripts/psql.sh -c "SELECT bike.generator_schedule('1 minute')"
```

### 9. 인용할 만한 수치

| | |
|---|---|
| 대여소 | 25개 자치구 2,789개 |
| 대여 | 228일간 24,037,356건 |
| 테이블 크기 | 7.1 GB (인덱스 포함 행당 256바이트) |
| WAL 생성량 | 행당 811바이트 |
| 실제 한 달 적재 | COPY로 164만 행 53초 |
| UTC 변환 | 23.87M 행 689초, 25만 행 배치 |
| 백필 | 2,220만 행 생성·적재 |
| 기본키 추가 | 164만 행 7.7초 |
| 실시간 피드 | 비피크 시간대 5분당 약 480건 |
