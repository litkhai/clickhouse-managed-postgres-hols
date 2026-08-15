# PostGIS + pg_clickhouse — Seoul public bike

Geography stays in Postgres; the counting moves to ClickHouse. A dashboard shows,
per query, which side actually answered.

[English](#english) | [한국어](#한국어)

---

## English

**The claim:** you do not have to choose between Postgres and ClickHouse. Keep
the geography in Postgres, send only the counting to ClickHouse, and neither
side does the thing it is bad at.

```
bike.stations   2,789 rows, PostGIS points      ← barely changes
bike.trips      24M rows and growing            ← only ever counted
                joined on an integer station id
```

That join key is the whole trick. It is an integer, so no geometry ever has to
reach the aggregating side.

```
   PostGIS (local only)      pg_clickhouse (FDW)        ClickHouse
   ────────────────────      ───────────────────        ──────────
   geometry: geom            small result comes back ←  trips + stations
   Voronoi, KNN, DBSCAN,                                GROUP BY *and* the
   ST_Distance, azimuth                                 join both run here
```

**And it works.** Same SQL, both sides, 28-day window over 24M rows:

| | plan | rows it moved | time |
|---|---|---|---|
| Postgres, local tables | 10 nodes — hash join, sort, aggregate | 3,459,577 through the sort | 9.6 s |
| ClickHouse, foreign tables | **one Foreign Scan** | 15 rows back | 1.3 s |

ClickHouse's own `system.query_log` confirms it independently: 24.11M rows read
*there*, 15 returned. All five aggregates push down, including the
`extract(hour FROM started_at + interval '9 hours')` the KST filters generate —
it arrives as `toHour(started_at + 32400)`.

**Verified 2026-08-15** against a live ClickHouse Managed Postgres service in
`ap-northeast-2`: PostgreSQL 18.4, PostGIS 3.6.4, pg_clickhouse 0.3, pg_cron 1.6.

### Quickstart

```bash
ln -s ../provisioning/config.env config.env   # or fill in config.env.example

./scripts/fetch-data.sh                       # ~275 MB, about 45s
./scripts/load-stations.sh                    # 2,789 rows into PostGIS
./scripts/load-trips.sh                       # 1.6M rows, about 55s
./scripts/backfill-trips.sh                   # fill every missing day since
./scripts/catch-up.sh                         # close the gap to now

./scripts/psql.sh -f /sql/30-generator-in-db.sql          # server-side feed
./scripts/psql.sh -c "SELECT bike.generator_schedule('1 minute')"
```

Then, to let the aggregates move (needs a ClickHouse service with the two tables
already replicated into it by ClickPipes):

```bash
./scripts/psql.sh -v ch_host=... -v ch_pass=... -f /sql/40-fdw-clickhouse.sql
```

`psql` runs in a container, so nothing needs installing. Output masks the
hostname, which carries the service name and id. Credentials live in a
gitignored `config.env` — this repository is public.

### The dashboard

```bash
cd ui && FOREIGN_SCHEMA=ch docker compose --env-file ../config.env up --build
open http://localhost:8080
```

Korean by default; `?lang=en` or the KO/EN switch in the header for English.

| Tab | |
|---|---|
| **Dashboard** | Map and charts on one grid: station demand from PostGIS, trips per bucket, hour of day, busiest districts, trip length |
| **Maps** | The four spatial queries, each with the SQL and plan that produced it |
| **Statistics** | The five aggregates, with a switch for **which side answers** — `bike` locally or `ch` on ClickHouse |
| **Pushdown** | The same query on both sides at once: timings, the Remote SQL actually sent, and how many rows each plan moved |
| **Log** | Every query the session ran, with its verdict, widest plan node and what crossed the wire |

One filter drives all of them: a range preset (1d / 1w / 1mo / 3mo / 6mo / 1y /
custom, counted back from the newest trip), a bucket constrained to fit that
range, districts, hours, weekday or weekend, and a minimum group size.

**Only the pulse polls.** It is index work and costs about 200 ms. Anything that
scans waits for **Run query**, because at 24M rows a daily rollup is 5 s and
`count(DISTINCT started_at::date)` is 14 s — measured, which is why they are not
on a timer. Leaving `FOREIGN_SCHEMA` unset is fine; the page then says plainly
that there is nothing to push down to, rather than reporting a failed pushdown.

### Why this dataset

Seoul's public bike history is one row per trip with a start and an end station,
which makes the split the lab is about fall out naturally:

| Side | What it holds | Size |
|------|---------------|------|
| **PostGIS** | 대여소 — station points, districts, addresses | 2,789 rows, static |
| **Facts** | 대여이력 — one row per trip | ~1.6M rows *per month* |

Both datasets are 서울 열린데이터광장 open data under **공공누리 제1유형**:
attribution, commercial use and modification allowed. No API key and no account.

### The two query sets

| Query set | |
|---|---|
| `sql/10-spatial-postgres.sql` | Five spatial queries that **cannot** leave Postgres — Voronoi service areas, KNN through the GiST index, DBSCAN clusters, detour factor against the geodesic, net flow and its bearing |
| `sql/20-aggregate-pushdown.sql` | Five aggregates that **should** run on ClickHouse — nothing but `WHERE`, `GROUP BY`, `HAVING` and plain aggregates over millions of rows |

**Proving the second half moved:**

```bash
./scripts/explain-pushdown.sh
```

`EXPLAIN (VERBOSE)` prints the SQL the wrapper will send. If `Remote SQL` carries
the `GROUP BY`, ClickHouse did the work. If it only selects columns and there is
an `Aggregate` above it, every row crossed the network and Postgres counted them
— slower than never moving the table. Nothing warns you about this; you have to
look. The Pushdown tab does the same thing per query, and adds the row counts.

**What breaks pushdown is mixing in a *local* table, not joining as such.**
ClickPipes replicates `bike.stations` too, so naming a station is remote work
like everything else. What cannot move is the geometry: `geom` has no ClickHouse
equivalent.

### The tables

`bike.stations` mirrors the spreadsheet and adds `geom geometry(Point, 4326)`,
built from the published lat/lon. `bike.trips` keeps all sixteen source columns
in their original order, plus a surrogate `trip_id`.

The surrogate key is not decoration. The source has no natural one — all five of
`bike_id`, both timestamps and both station ids still leave 96 rows non-unique,
and those are real distinct trips that differ only in the distance recorded. And
logical replication needs a replica identity: without a primary key ClickPipes
refuses the table outright. Adding it to 1.64M rows took 7.7s.

There is **no foreign key** from trips to stations. The history references
stations the current master no longer lists — they get retired, and the master
is a snapshot — so the constraint would reject real rows. 17 station numbers in
January's history are absent from the master, across 26,346 trips.

### Filling the gap, and keeping it filled

`backfill-trips.sh` asks the database which days between the first loaded trip
and yesterday have no rows, and writes only those. Taking `max(started_at) + 1`
as the starting point would have been simpler and was wrong — one streaming test
had already put rows on today's date, which made February through August look
covered.

```
$ ./scripts/backfill-trips.sh --explain
  weekday 60388 / weekend 37893 trips per day
  days       : 195 missing, 2026-02-01 .. 2026-08-14
  estimate   : 22,202,682 trips at scale 1.0
  extrapolated months (no published data): [7, 8]
```

Full volume is 22M rows, and every one replicates downstream, so it asks before
starting. `--scale 0.1` gives the same shape at a tenth the size.

**How the trips are made.** A generated trip is a real trip with a new
timestamp, drawn from the pool of real trips that started in the same hour of
the same kind of day. Every field here correlates with every other — morning
trips run to subway stations and last eight minutes, Sunday afternoon trips run
along the river and last forty — so drawing each column from its own
distribution would reproduce all the histograms and none of the joint structure.
The OD matrix would go uniform and the aggregates this lab exists to demonstrate
would flatten out.

Measured against the real month, a generated week matches closely:

| | real (Jan) | generated |
|---|---|---|
| share of weekday trips at 08:00 | 28.16% | 28.20% |
| share at 18:00 | 26.55% | 26.49% |
| mean duration | 17.1 min | 17.0 min |
| mean distance | 1,724 m | 1,718 m |
| round trips | 8.6% | 8.7% |

What is *not* measured is the month-to-month scale — only January is loaded. The
published monthly file sizes stand in for trip counts, and July and August are
extrapolated because they are not published yet. `--explain` names the guessed
months.

### Time zones

`started_at` and `ended_at` are **UTC**. The source publishes Korean local time
and the column carries no zone, so the distinction had to be decided rather than
inherited: ClickHouse attaches a timezone to `DateTime`, and KST wall-clock
arriving there would quietly mean nine hours earlier.

Seoul is UTC+9 with no daylight saving, so the weekday peaks sit at 23:00 and
09:00 UTC. Everything the dashboard shows converts back — a KST day is the UTC
range `[D−9h, D+1−9h)`, done in one place.

Getting this wrong is silent. The in-database generator first read
`AT TIME ZONE 'Asia/Seoul'` while the table was still KST, and generated the
07:00 shape at 16:45 — the rows looked entirely plausible.

### Replicating out

ClickPipes/PeerDB picks up both tables once each has a primary key. From the
Postgres side, a running mirror looks like this:

```sql
SELECT slot_name, plugin, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS unconsumed
FROM pg_replication_slots;

SELECT application_name, state, replay_lag FROM pg_stat_replication;
```

`confirmed_flush_lsn` advances in steps rather than continuously, because the
consumer confirms once a batch has landed downstream — watching it for five
seconds and concluding it is stuck is a mistake worth not making.

Watch two things. An **inactive slot retains WAL indefinitely** and will fill the
disk, so `SELECT count(*) FROM pg_replication_slots WHERE NOT active` belongs in
whatever you monitor. And the publication here names its tables explicitly; a
`FOR ALL TABLES` publication would sweep up the generator's working tables too,
which is why they live in a separate `bikegen` schema.

### Files

```
sql/01-schema.sql             stations (PostGIS) + trips, UTC noted on the column
sql/02-verify.sql             what loaded, and where the data disagrees with itself
sql/10-spatial-postgres.sql   five queries that stay
sql/20-aggregate-pushdown.sql five that travel
sql/30-generator-in-db.sql    pg_cron + procedure, model tables in bikegen
sql/40-fdw-clickhouse.sql     ch.trips / ch.stations over the ClickHouse copy

scripts/fetch-data.sh         download, with filename verification
scripts/load-stations.sh      xlsx → PostGIS, geometry + GiST index
scripts/load-trips.sh         CP949 → UTF-8, KST → UTC, staged then cast
scripts/backfill-trips.sh     fill missing days
scripts/catch-up.sh           fill the hours since the newest trip
scripts/shift-to-utc.sh       one-off conversion, primary-key batches
scripts/generate-trips.sh     client-side live feed
scripts/explain-pushdown.sh   did it push down?
scripts/psql.sh               psql in a container

ui/app.py                     stdlib + psycopg; walks EXPLAIN JSON for the verdict
ui/index.html                 dashboard, maps, statistics, pushdown, log
```

### Notes on the source

The portal serves files over a plain POST, keyed by an internal sequence number
per file plus an `infSeq` per dataset. Those numbers are pinned in
`fetch-data.sh` because the portal exposes no lookup for them. Get `infSeq`
wrong and it does not error — it serves **a different dataset's file**. The first
attempt while writing this pulled down an unrelated 1 GB binary. The script
checks the filename in the response and refuses anything unexpected.

The CSVs are CP949.

### Further reading

[WRITEUP.md](WRITEUP.md) — how it was built, in order, with the mistakes left
in: why this dataset, what the platform provided, the UTC decision, how the
synthetic trips are modelled, what it took to prove pushdown, and what the
dashboard forced. Written as source material for a longer article.

### 📄 License

[MIT](../../LICENSE) — same as the rest of the repository. The data is not
redistributed here; `fetch-data.sh` pulls it from 서울 열린데이터광장 under
공공누리 제1유형, and `data/` is gitignored.

---

## 한국어

**주장:** Postgres냐 ClickHouse냐를 고를 필요가 없습니다. 지리는 Postgres에 두고
집계만 ClickHouse로 보내면, 양쪽 모두 잘 못하는 일을 하지 않습니다.

```
bike.stations   2,789행, PostGIS 포인트     ← 거의 안 변함
bike.trips      2,400만 행, 계속 증가       ← 집계만 함
                정수 대여소번호로 조인
```

조인 키가 정수라는 게 핵심입니다. 지오메트리가 집계하는 쪽으로 건너갈 일이
없습니다.

```
   PostGIS (로컬 전용)       pg_clickhouse (FDW)      ClickHouse
   ─────────────────────     ───────────────────      ──────────
   지오메트리: geom          작은 결과만 회수    ←    trips + stations
   Voronoi, KNN, DBSCAN,                              GROUP BY 도 조인도
   ST_Distance, 방위각                                여기서 실행
```

**그리고 실제로 됩니다.** 같은 SQL, 양쪽, 2,400만 행 중 28일 구간:

| | 플랜 | 옮긴 행 | 시간 |
|---|---|---|---|
| Postgres, 로컬 테이블 | 노드 10개 — 해시 조인·정렬·집계 | 정렬을 통과한 3,459,577행 | 9.6초 |
| ClickHouse, foreign table | **Foreign Scan 하나** | 회수 15행 | 1.3초 |

ClickHouse 자신의 `system.query_log`가 독립적으로 확인해 줍니다 — *저쪽에서*
24.11M 행을 읽고 15행 반환. 집계 다섯 개가 모두 푸시다운되며, KST 필터가 만드는
`extract(hour FROM started_at + interval '9 hours')`도 포함입니다 —
`toHour(started_at + 32400)`으로 도착합니다.

**2026-08-15 검증**, `ap-northeast-2`의 실제 ClickHouse Managed Postgres 서비스
기준: PostgreSQL 18.4, PostGIS 3.6.4, pg_clickhouse 0.3, pg_cron 1.6.

### 빠른 시작

```bash
ln -s ../provisioning/config.env config.env   # 또는 config.env.example 작성

./scripts/fetch-data.sh                       # 약 275 MB, 45초
./scripts/load-stations.sh                    # 2,789행 PostGIS 적재
./scripts/load-trips.sh                       # 164만 행, 약 55초
./scripts/backfill-trips.sh                   # 이후 빠진 날짜 전부 채움
./scripts/catch-up.sh                         # 지금까지의 공백 메움

./scripts/psql.sh -f /sql/30-generator-in-db.sql          # 서버 사이드 피드
./scripts/psql.sh -c "SELECT bike.generator_schedule('1 minute')"
```

집계를 옮기려면 (ClickPipes로 두 테이블이 이미 복제된 ClickHouse 서비스가
필요합니다):

```bash
./scripts/psql.sh -v ch_host=... -v ch_pass=... -f /sql/40-fdw-clickhouse.sql
```

`psql`은 컨테이너로 실행하므로 설치할 게 없습니다. 호스트명에 서비스 이름과 id가
들어 있어 출력은 마스킹됩니다. 자격증명은 gitignore된 `config.env`에 둡니다 — 이
저장소는 공개입니다.

### 대시보드

```bash
cd ui && FOREIGN_SCHEMA=ch docker compose --env-file ../config.env up --build
open http://localhost:8080
```

기본 언어는 한국어이고, `?lang=en` 또는 헤더의 KO/EN 전환으로 영어를 볼 수
있습니다.

| 탭 | |
|---|---|
| **대시보드** | 맵과 차트를 한 그리드에: PostGIS 대여소 수요, 기간별 대여, 시간대별, 자치구 순위, 이용 시간 |
| **지도** | 공간 쿼리 4종 — 각각 그 지도를 만든 SQL과 실행 계획을 함께 |
| **통계** | 집계 5종. **어느 쪽이 답하는지** 전환 — 로컬 `bike` 또는 ClickHouse `ch` |
| **푸시다운** | 같은 쿼리를 양쪽에서 동시에: 소요 시간, 실제로 전송된 Remote SQL, 각 플랜이 옮긴 행 수 |
| **로그** | 세션이 실행한 모든 쿼리 — 판정, 최대 플랜 노드, 네트워크를 건넌 행 |

필터 하나가 전부를 움직입니다. 기간 프리셋(1일 / 1주 / 1개월 / 3개월 / 6개월 /
1년 / 사용자 지정, 최신 대여에서 거슬러 계산), 그 기간에 맞게 제한된 버킷,
자치구, 시간대, 평일/주말, 그룹 최소 건수.

**폴링하는 것은 pulse뿐입니다.** 인덱스 작업이라 약 200 ms입니다. 스캔하는 것은
전부 **쿼리 실행**을 기다립니다. 2,400만 행에서 일별 롤업이 5초,
`count(DISTINCT started_at::date)`가 14초이기 때문입니다 — 측정값이고, 그래서
타이머에 걸지 않았습니다. `FOREIGN_SCHEMA`를 비워 둬도 됩니다. 그러면 화면이
푸시다운 실패라고 보고하는 대신 보낼 대상이 없다고 명확히 말합니다.

### 왜 이 데이터인가

서울 따릉이 대여이력은 대여 한 건이 한 행이고 출발·반납 대여소를 갖고 있어, 이
랩이 다루는 분리가 자연스럽게 나옵니다.

| 쪽 | 담는 것 | 크기 |
|---|---|---|
| **PostGIS** | 대여소 — 포인트, 자치구, 주소 | 2,789행, 정적 |
| **팩트** | 대여이력 — 대여 한 건이 한 행 | **월** 164만 행 |

두 데이터셋 모두 서울 열린데이터광장 공개 데이터, **공공누리 제1유형**입니다 —
출처 표시 후 상업적 이용과 변형 가능. API 키도 계정도 필요 없습니다.

### 쿼리 세트 둘

| 쿼리 세트 | |
|---|---|
| `sql/10-spatial-postgres.sql` | Postgres를 떠날 수 **없는** 공간 쿼리 5개 — Voronoi 세력권, GiST 최근접, DBSCAN 군집, 측지선 대비 우회율, 순유출입과 방위 |
| `sql/20-aggregate-pushdown.sql` | ClickHouse에서 돌아야 **하는** 집계 5개 — 수백만 행에 대해 `WHERE`·`GROUP BY`·`HAVING`과 기본 집계만 |

**후자가 실제로 넘어갔는지 증명:**

```bash
./scripts/explain-pushdown.sh
```

`EXPLAIN (VERBOSE)`는 래퍼가 보낼 SQL을 출력합니다. `Remote SQL`에 `GROUP BY`가
있으면 ClickHouse가 처리한 것입니다. 컬럼만 뽑고 위에 `Aggregate`가 있으면 모든
행이 네트워크를 건너와 Postgres가 센 것이며, 테이블을 옮기지 않느니만 못합니다.
**아무도 경고해 주지 않으니 직접 봐야 합니다.** 푸시다운 탭이 쿼리별로 같은 일을
하고 행 수까지 붙여 줍니다.

**푸시다운을 깨는 것은 조인 자체가 아니라 *로컬* 테이블을 섞는 것입니다.**
ClickPipes가 `bike.stations`도 복제하므로 대여소 이름을 붙이는 것도 다른 모든 것과
마찬가지로 원격 작업입니다. 옮길 수 없는 건 지오메트리입니다 — `geom`에는
ClickHouse 대응물이 없습니다.

### 테이블

`bike.stations`는 스프레드시트를 그대로 옮기고 공개된 위경도로 만든
`geom geometry(Point, 4326)`을 더합니다. `bike.trips`는 원본 16개 컬럼을 원래
순서대로 두고 대리키 `trip_id`를 더합니다.

대리키는 장식이 아닙니다. 원본에 자연키가 없습니다 — `bike_id`와 두 타임스탬프,
두 대여소번호를 다 써도 96행이 중복으로 남고, 그것들은 기록된 거리만 다른 진짜
별개의 대여입니다. 그리고 논리 복제에는 replica identity가 필요합니다. 기본키가
없으면 ClickPipes가 테이블을 아예 거부합니다. 164만 행에 추가하는 데 7.7초.

trips에서 stations로 가는 **외래키는 없습니다.** 이력에는 현재 마스터에 없는
대여소가 나옵니다 — 폐지되기도 하고 마스터는 스냅숏이니까요 — 제약이 있으면 진짜
행을 거부하게 됩니다. 1월 이력의 대여소번호 17개가 마스터에 없고, 26,346건에
해당합니다.

### 빠진 구간 채우기, 그리고 계속 채우기

`backfill-trips.sh`는 처음 적재된 대여부터 어제까지 중 행이 없는 날을 DB에 묻고
그 날짜만 씁니다. `max(started_at) + 1`을 시작점으로 잡는 쪽이 더 간단했고
틀렸습니다 — 스트리밍 테스트가 이미 오늘 날짜에 행을 넣어 둬서 2월부터 8월까지가
채워진 것처럼 보였습니다.

```
$ ./scripts/backfill-trips.sh --explain
  weekday 60388 / weekend 37893 trips per day
  days       : 195 missing, 2026-02-01 .. 2026-08-14
  estimate   : 22,202,682 trips at scale 1.0
  extrapolated months (no published data): [7, 8]
```

전체 규모는 2,200만 행이고 전부 하류로 복제되므로 시작 전에 확인을 받습니다.
`--scale 0.1`이면 같은 모양을 10분의 1 크기로 만듭니다.

**대여를 만드는 방법.** 생성된 대여는 새 타임스탬프를 가진 실제 대여이고, 같은
종류의 날 같은 시각에 출발한 실제 대여 풀에서 뽑습니다. 여기서는 모든 필드가 서로
상관됩니다 — 아침 대여는 지하철역으로 가고 8분이 걸리며, 일요일 오후 대여는
강변을 따라 40분이 걸립니다 — 그래서 컬럼마다 자기 분포에서 뽑으면 히스토그램은 다
맞고 결합 구조는 하나도 남지 않습니다. OD 행렬이 균일해지고, 이 랩이 존재하는
이유인 바로 그 집계가 평평해집니다.

실제 한 달과 비교하면 생성된 한 주가 근접합니다.

| | 실제 (1월) | 생성 |
|---|---|---|
| 평일 08시 비중 | 28.16% | 28.20% |
| 18시 비중 | 26.55% | 26.49% |
| 평균 이용시간 | 17.1분 | 17.0분 |
| 평균 거리 | 1,724 m | 1,718 m |
| 왕복 비율 | 8.6% | 8.7% |

측정되지 *않은* 것은 월별 규모입니다 — 1월만 적재했으니까요. 공개된 월별 파일
크기가 대여 건수를 대신하고, 7·8월은 아직 공개되지 않아 외삽입니다.
`--explain`이 추정한 달의 이름을 밝힙니다.

### 시간대

`started_at`과 `ended_at`은 **UTC**입니다. 원본은 한국 지역시로 발행되고 컬럼에
존이 없어서, 이 구분은 물려받는 대신 결정해야 했습니다. ClickHouse는 `DateTime`에
타임존을 붙이므로, KST 벽시계가 저기 도착하면 조용히 아홉 시간 이르다는 뜻이
됩니다.

서울은 서머타임 없는 UTC+9이라 평일 피크가 UTC 23:00과 09:00에 있습니다.
대시보드가 보여주는 것은 전부 되돌려 표시합니다 — KST의 하루는 UTC 구간
`[D−9h, D+1−9h)`이고, 변환은 한 곳에서만 합니다.

이걸 틀리면 조용합니다. DB 내장 생성기가 테이블이 아직 KST일 때
`AT TIME ZONE 'Asia/Seoul'`을 읽어 16:45에 07:00의 모양을 생성했습니다. 행들은
아주 그럴듯해 보였습니다.

### 복제 내보내기

ClickPipes/PeerDB는 각 테이블에 기본키가 있으면 가져갑니다. Postgres 쪽에서 보면
돌고 있는 미러는 이렇게 보입니다.

```sql
SELECT slot_name, plugin, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS unconsumed
FROM pg_replication_slots;

SELECT application_name, state, replay_lag FROM pg_stat_replication;
```

`confirmed_flush_lsn`은 연속이 아니라 계단식으로 전진합니다. 소비자가 배치가
하류에 안착한 뒤에 확인하기 때문입니다 — 5초 보고 멈췄다고 결론 내리지 않는 편이
좋습니다.

두 가지를 봐야 합니다. **비활성 슬롯은 WAL을 무한히 붙잡아** 디스크를 채웁니다.
`SELECT count(*) FROM pg_replication_slots WHERE NOT active`는 모니터링에 넣을
가치가 있습니다. 그리고 여기 publication은 테이블을 명시적으로 나열합니다.
`FOR ALL TABLES`였다면 생성기의 작업 테이블까지 쓸어 담았을 것이고, 그래서 그것들은
별도 `bikegen` 스키마에 있습니다.

### 파일

```
sql/01-schema.sql             stations(PostGIS) + trips, 컬럼 주석에 UTC 명시
sql/02-verify.sql             무엇이 적재됐고 데이터가 어디서 모순되는지
sql/10-spatial-postgres.sql   남아야 하는 쿼리 5개
sql/20-aggregate-pushdown.sql 옮겨야 하는 쿼리 5개
sql/30-generator-in-db.sql    pg_cron + 프로시저, 모델 테이블은 bikegen
sql/40-fdw-clickhouse.sql     ClickHouse 복제본 위의 ch.trips / ch.stations

scripts/fetch-data.sh         다운로드, 파일명 검증 포함
scripts/load-stations.sh      xlsx → PostGIS, 지오메트리 + GiST 인덱스
scripts/load-trips.sh         CP949 → UTF-8, KST → UTC, 스테이징 후 캐스팅
scripts/backfill-trips.sh     빠진 날짜 채우기
scripts/catch-up.sh           최신 대여 이후 시각 단위 공백 채우기
scripts/shift-to-utc.sh       1회 변환, PK 구간 단위
scripts/generate-trips.sh     클라이언트 측 실시간 피드
scripts/explain-pushdown.sh   푸시다운 됐나?
scripts/psql.sh               컨테이너 psql

ui/app.py                     표준 라이브러리 + psycopg. EXPLAIN JSON을 순회해 판정
ui/index.html                 대시보드·지도·통계·푸시다운·로그
```

### 원본에 대한 참고

포털은 평범한 POST로 파일을 주는데, 파일별 내부 시퀀스 번호와 데이터셋별
`infSeq`로 식별됩니다. 포털이 조회 수단을 제공하지 않아 그 번호들은
`fetch-data.sh`에 고정되어 있습니다. `infSeq`를 틀리면 에러가 나지 않고 **다른
데이터셋의 파일**을 줍니다. 이 문서를 쓰는 중 첫 시도에서 관계없는 1 GB 바이너리를
받았습니다. 스크립트는 응답의 파일명을 확인하고 예상 밖이면 거부합니다.

CSV는 CP949입니다.

### 더 읽을거리

[WRITEUP.md](WRITEUP.md) — 만든 과정을 순서대로, 틀렸던 것도 그대로: 데이터 선정
이유, 플랫폼이 제공한 것, UTC 결정, 합성 대여 모델링, 푸시다운을 증명하기까지,
그리고 대시보드가 강제한 것들. 더 긴 글의 원재료로 썼습니다.

### 📄 라이선스

[MIT](../../LICENSE) — 저장소의 나머지와 동일합니다. 데이터는 여기에 재배포하지
않습니다. `fetch-data.sh`가 서울 열린데이터광장에서 공공누리 제1유형으로 받아오고
`data/`는 gitignore되어 있습니다.
