# PostGIS + pg_clickhouse — Seoul public bike

[English](#english) | [한국어](#한국어)

---

## English

Geography stays in Postgres; aggregation is what moves to ClickHouse.

**This directory covers the Postgres half.** It loads the data and keeps it
moving. Wiring the ClickHouse side and the foreign server is deliberately left
out — see [Where this stops](#where-this-stops).

**Verified 2026-08-15** against a live ClickHouse Managed Postgres service in
`ap-northeast-2` (PostgreSQL 18.4, PostGIS 3.6.4): 2,789 stations and 1,640,582
January 2026 trips loaded, spatial join and streaming insert both exercised.

### Why this dataset

Seoul's public bike history is one row per trip with a start and an end station,
which makes the split the lab is about fall out naturally:

| Side | What it holds | Size |
|------|---------------|------|
| **PostGIS** | 대여소 — station points, districts, addresses | 2,789 rows, static |
| **Facts** | 대여이력 — one row per trip | ~1.6M rows *per month* |

The join key is a station number, an integer. No geometry ever has to cross to
the aggregating side, so the spatial work has no reason to leave Postgres —
which is the point.

Both datasets are 서울 열린데이터광장 open data under
**공공누리 제1유형**: attribution, commercial use and modification allowed. No
API key and no account.

### Run it

```bash
ln -s ../provisioning/config.env config.env   # or fill in config.env.example
./scripts/fetch-data.sh                       # ~275 MB, about 45s
./scripts/load-stations.sh                    # 2,789 rows into PostGIS
./scripts/load-trips.sh                       # 1.6M rows, about 55s
./scripts/stream-trips.sh                     # keeps inserting until Ctrl-C
```

`psql` runs in a container, so nothing needs installing. Output masks the
hostname, which carries the service name and id.

| Script | What it does |
|--------|--------------|
| `fetch-data.sh [month …]` | Downloads station master and trip months into `data/` |
| `load-stations.sh` | Applies `sql/01-schema.sql`, loads stations, builds `geom` and a GiST index |
| `load-trips.sh [month …]` | Stages the CP949 CSV, casts it, indexes it |
| `backfill-trips.sh` | Fills every missing day between the loaded history and yesterday |
| `generate-trips.sh` | Live feed at the rate this hour of this weekday calls for |
| `explain-pushdown.sh` | Says whether a query ran remotely or was dragged back |
| `psql.sh` | psql against the service; `-f /sql/02-verify.sql` for the checks |

| Query set | |
|---|---|
| `sql/10-spatial-postgres.sql` | Five spatial queries that cannot leave Postgres |
| `sql/20-aggregate-pushdown.sql` | Five aggregates meant to run on ClickHouse |

### The tables

`bike.stations` mirrors the spreadsheet and adds `geom geometry(Point, 4326)`,
built from the published lat/lon. `bike.trips` keeps all sixteen source columns
in their original order, plus a surrogate `trip_id`, so a ClickHouse table can
mirror it when the fact side moves.

The surrogate key is not decoration. The source has no natural one — all five of
`bike_id`, both timestamps and both station ids still leave 96 rows non-unique,
and those are real distinct trips that differ only in the distance recorded. And
logical replication needs a replica identity: without a primary key ClickPipes
refuses the table with *"cannot be replicated because they don't have a valid
replica identity"*. `REPLICA IDENTITY FULL` would also clear that, but a
`bigint` key gives the ClickHouse side something sensible to order and
deduplicate on. Adding it to 1.64M rows took 7.7s.

There is **no foreign key** from trips to stations. The history references
stations the current master no longer lists — they get retired, and the master
is a snapshot — so the constraint would reject real rows. 17 station numbers in
January's history are absent from the master, across 26,346 trips.

### Filling the gap, and keeping it filled

Two scripts, because they answer different questions.

`backfill-trips.sh` asks the database which days between the first loaded trip
and yesterday have no rows, and writes only those. Taking `max(started_at) + 1`
as the starting point would have been simpler and was wrong — one streaming
test had already put rows on today's date, which made February through August
look covered.

```
$ ./scripts/backfill-trips.sh --explain
  weekday 60388 / weekend 37893 trips per day
  days       : 195 missing, 2026-02-01 .. 2026-08-14
  estimate   : 22,202,682 trips at scale 1.0
  extrapolated months (no published data): [7, 8]
```

Full volume is 22M rows, and every one replicates downstream, so it asks before
starting. `--scale 0.1` gives the same shape at a tenth the size.

`generate-trips.sh` runs continuously at whatever rate the current hour of the
current weekday calls for, so an 8am Tuesday inserts several times what a 4am
Tuesday does. Counts vary between windows — arrivals are drawn from a Poisson,
because a fixed rate makes the feed tick like a metronome.

**How the trips are made.** A generated trip is a real trip with a new
timestamp, drawn from the pool of real trips that started in the same hour of
the same kind of day. Every field here correlates with every other — morning
trips run to subway stations and last eight minutes, Sunday afternoon trips run
along the river and last forty, rider age shifts with both — so drawing each
column from its own distribution would reproduce all the histograms and none of
the joint structure. The OD matrix would go uniform and the aggregates this lab
exists to demonstrate would flatten out.

Measured against the real month, a generated week matches closely:

| | real (Jan) | generated |
|---|---|---|
| share of weekday trips at 08:00 | 28.16% | 28.20% |
| share at 18:00 | 26.55% | 26.49% |
| mean duration | 17.1 min | 17.0 min |
| mean distance | 1,724 m | 1,718 m |
| round trips | 8.6% | 8.7% |

What is *not* measured is the month-to-month scale — only January is loaded.
The published monthly file sizes stand in for trip counts (280, 307, 501, 674,
690, 716 MB for 2026-01 to 06), and July and August are extrapolated from June
because they are not published yet. `--explain` names the guessed months.

One honest limit: sampling every *n*th trip misses the rarest stations, so a
generated week covered 2,541 of the 2,768 origin stations. Raise `--sample` if
that matters.

### What the spatial side looks like

Straight-line distance between the two stations of every trip, by district —
the kind of thing that has no business leaving Postgres:

```sql
SELECT s.district,
       count(*)                       AS departures,
       round(avg(t.duration_min), 1)  AS avg_min,
       round(avg(ST_Distance(s.geom::geography, e.geom::geography))::numeric) AS avg_crow_m
FROM bike.trips t
JOIN bike.stations s ON s.station_id = t.start_station_id
JOIN bike.stations e ON e.station_id = t.end_station_id
GROUP BY s.district ORDER BY departures DESC LIMIT 5;
```

```
 district | departures | avg_min | avg_crow_m
----------+------------+---------+------------
 강서구   |     227025 |    12.4 |       1022
 영등포구 |     150935 |    16.7 |       1128
 송파구   |     144225 |    17.4 |       1224
 양천구   |     108882 |    15.6 |       1120
 노원구   |      95279 |    17.4 |       1207
```

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
seconds and concluding it is stuck is a mistake worth not making. Measured here:
1,492 inserted rows pushed unconsumed WAL to 36 MB, which drained to zero within
about half a minute.

Watch two things. An **inactive slot retains WAL indefinitely** and will fill the
disk, so `SELECT count(*) FROM pg_replication_slots WHERE NOT active` belongs in
whatever you monitor. And the publication here names its tables explicitly; a
`FOR ALL TABLES` publication would sweep up scratch tables too, which is why
`stream-trips.sh` drops its sample table on exit.

### Where this stops

The aggregate above scans 1.6M rows in Postgres. That is exactly the work that
belongs in ClickHouse, with `bike.trips` behind a foreign table and only the
grouped result coming back to be joined against `bike.stations`.

That wiring is not here. One thing to know before doing it: **the FDW connects
outward from the Postgres server**, so a ClickHouse on your laptop is not
reachable from a managed service in AWS — it has to be somewhere the service
can dial. And PostGIS geometry has no ClickHouse equivalent, so spatial
predicates will not push down; keep the boundary at the integer station id.

### Notes on the source

The portal serves files over a plain POST, keyed by an internal sequence number
per file plus an `infSeq` per dataset. Those numbers are pinned in
`fetch-data.sh` because the portal exposes no lookup for them. Get `infSeq`
wrong and it does not error — it serves **a different dataset's file**. The
first attempt while writing this pulled down an unrelated 1 GB binary. The
script checks the filename in the response and refuses anything unexpected.

The CSVs are CP949.

### 📄 License

[MIT](../../LICENSE) — same as the rest of the repository. The data is not
redistributed here; `fetch-data.sh` pulls it from 서울 열린데이터광장 under
공공누리 제1유형, and `data/` is gitignored.

---

## 한국어

지리 연산은 Postgres에 남기고, ClickHouse로 내려보내는 것은 집계뿐입니다.

**이 디렉토리는 Postgres 쪽만 다룹니다.** 데이터를 적재하고 계속 흘려 넣는
데까지입니다. ClickHouse 연결과 외래 서버 구성은 의도적으로 빠져 있습니다 —
[여기서 멈추는 이유](#여기서-멈추는-이유) 참조.

**2026-08-15 검증** — `ap-northeast-2`의 실제 ClickHouse Managed Postgres
서비스(PostgreSQL 18.4, PostGIS 3.6.4)에서 대여소 2,789개와 2026년 1월 대여이력
1,640,582건을 적재하고, 공간 조인과 스트리밍 삽입을 모두 실행했습니다.

### 왜 이 데이터인가

서울 공공자전거 대여이력은 한 행이 한 번의 대여이고 출발·도착 대여소가 모두
들어 있어서, 이 랩이 보여주려는 분업이 자연스럽게 떨어집니다.

| 쪽 | 담는 것 | 규모 |
|---|---|---|
| **PostGIS** | 대여소 — 좌표, 자치구, 주소 | 2,789행, 사실상 고정 |
| **팩트** | 대여이력 — 대여 1건당 1행 | **월** 약 164만 행 |

조인 키는 대여소번호, 즉 정수입니다. 지오메트리가 집계하는 쪽으로 건너갈 일이
없으니 공간 연산이 Postgres를 떠날 이유도 없습니다 — 그게 요점입니다.

두 데이터셋 모두 서울 열린데이터광장 공개 데이터이며 **공공누리 제1유형**
(출처표시, 상업적 이용 및 변경 가능)입니다. API 키도 계정도 필요 없습니다.

### 실행

```bash
ln -s ../provisioning/config.env config.env   # 또는 config.env.example 작성
./scripts/fetch-data.sh                       # 약 275 MB, 45초
./scripts/load-stations.sh                    # 2,789행 PostGIS 적재
./scripts/load-trips.sh                       # 164만 행, 약 55초
./scripts/stream-trips.sh                     # Ctrl-C 까지 계속 삽입
```

`psql`은 컨테이너로 실행하므로 설치할 게 없습니다. 호스트명에 서비스 이름과
id가 들어 있어 출력은 마스킹됩니다.

| 스크립트 | 하는 일 |
|---|---|
| `fetch-data.sh [월 …]` | 대여소 마스터와 지정한 월의 대여이력을 `data/`로 다운로드 |
| `load-stations.sh` | `sql/01-schema.sql` 적용, 대여소 적재, `geom` 생성 + GiST 인덱스 |
| `load-trips.sh [월 …]` | CP949 CSV를 스테이징 후 타입 변환·인덱스 |
| `backfill-trips.sh` | 적재된 이력과 어제 사이의 **빠진 날짜를 모두** 채움 |
| `generate-trips.sh` | 지금 이 요일·이 시각에 맞는 속도로 계속 생성 |
| `explain-pushdown.sh` | 쿼리가 원격에서 돌았는지 끌려왔는지 판정 |
| `psql.sh` | 서비스에 psql 접속; 점검은 `-f /sql/02-verify.sql` |

| 쿼리 세트 | |
|---|---|
| `sql/10-spatial-postgres.sql` | Postgres를 떠날 수 없는 공간 쿼리 5개 |
| `sql/20-aggregate-pushdown.sql` | ClickHouse에서 돌아야 할 집계 5개 |

### 테이블

`bike.stations`는 원본 스프레드시트를 그대로 옮기고 공개된 위경도로
`geom geometry(Point, 4326)`을 만듭니다. `bike.trips`는 원본 16개 컬럼을 순서
그대로 유지하고 대리키 `trip_id`를 더합니다.

이 대리키는 장식이 아닙니다. 원본에 자연키가 없습니다 — `bike_id`와 양쪽
타임스탬프, 양쪽 대여소번호를 모두 합쳐도 96행이 겹치는데, 이는 중복이 아니라
기록된 거리만 다른 별개의 대여입니다. 그리고 논리 복제에는 replica identity가
필요해서, 기본키가 없으면 ClickPipes가 *"cannot be replicated because they
don't have a valid replica identity"*로 테이블을 거부합니다. `REPLICA IDENTITY
FULL`로도 해결되지만, `bigint` 키가 ClickHouse 쪽 정렬·중복제거 키로 쓰이므로
그쪽을 택했습니다. 164만 행에 추가하는 데 7.7초 걸렸습니다.

trips에서 stations로 가는 **외래키는 없습니다.** 이력에는 현재 마스터에 없는
대여소가 등장합니다(폐지되었고, 마스터는 스냅샷이라). 제약을 걸면 실제 데이터가
거부됩니다. 1월 이력의 대여소번호 17개가 마스터에 없고, 대여 26,346건이
여기 해당합니다.

### 빠진 구간 채우기, 그리고 계속 채우기

질문이 달라서 스크립트를 둘로 나눴습니다.

`backfill-trips.sh`는 첫 적재일부터 어제까지 중 **행이 없는 날짜를 DB에 직접
물어** 그 날짜만 씁니다. `max(started_at) + 1`을 시작점으로 잡는 편이 간단했지만
틀렸습니다 — 스트리밍 시험이 오늘 날짜에 행을 넣어둔 탓에 2월부터 8월까지가
"이미 채워짐"으로 판정됐습니다.

```
$ ./scripts/backfill-trips.sh --explain
  weekday 60388 / weekend 37893 trips per day
  days       : 195 missing, 2026-02-01 .. 2026-08-14
  estimate   : 22,202,682 trips at scale 1.0
  extrapolated months (no published data): [7, 8]
```

전체 물량은 2,200만 행이고 전부 하류로 복제되므로 실행 전에 확인을 받습니다.
`--scale 0.1`이면 모양은 같고 크기는 1/10입니다.

`generate-trips.sh`는 지금 이 요일·이 시각에 맞는 속도로 계속 돌립니다. 화요일
오전 8시는 화요일 새벽 4시의 몇 배를 넣습니다. 창(window)마다 건수가 달라지는데,
도착을 포아송에서 뽑기 때문입니다 — 고정 속도면 메트로놈처럼 똑같은 수만 나옵니다.

**생성 방식.** 생성된 대여는 *실제 대여에 새 타임스탬프를 붙인 것*이며, 같은
종류의 요일·같은 시각에 시작된 실제 대여 풀에서 뽑습니다. 여기서는 모든 필드가
서로 얽혀 있습니다 — 아침 대여는 지하철역으로 8분, 일요일 오후는 강변으로 40분,
연령대도 그에 따라 달라집니다. 컬럼별로 따로 뽑으면 히스토그램은 맞지만 결합
구조가 사라져 OD 행렬이 균등해지고, 이 랩이 보여주려는 집계가 밋밋해집니다.

실제 1월과 비교하면 생성 데이터가 잘 맞습니다.

| | 실제(1월) | 생성 |
|---|---|---|
| 평일 08시 비중 | 28.16% | 28.20% |
| 18시 비중 | 26.55% | 26.49% |
| 평균 소요시간 | 17.1분 | 17.0분 |
| 평균 거리 | 1,724 m | 1,718 m |
| 왕복 비율 | 8.6% | 8.7% |

**측정하지 않은 것**은 월별 규모입니다 — 1월만 적재돼 있어서요. 포털에 공개된
월별 파일 크기를 대여 건수의 대리 지표로 썼고(2026-01~06: 280, 307, 501, 674,
690, 716 MB), 7·8월은 아직 미공개라 6월에서 외삽했습니다. `--explain`이 추정
구간을 표시합니다.

한계 하나: *n*번째마다 뽑는 표본은 희소한 대여소를 놓쳐서, 생성한 한 주는 출발
대여소 2,768개 중 2,541개만 담았습니다. 중요하면 `--sample`을 올리세요.

### 공간 쪽은 이런 모양

각 대여의 출발–도착 직선거리를 자치구별로 — Postgres를 떠날 이유가 없는 연산:

```
 district | departures | avg_min | avg_crow_m
----------+------------+---------+------------
 강서구   |     227025 |    12.4 |       1022
 영등포구 |     150935 |    16.7 |       1128
 송파구   |     144225 |    17.4 |       1224
```

### 복제 내보내기

두 테이블 모두 기본키가 생기면 ClickPipes/PeerDB가 잡아갑니다. 동작 중일 때
Postgres 쪽에서 보이는 모습:

```sql
SELECT slot_name, plugin, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS unconsumed
FROM pg_replication_slots;

SELECT application_name, state, replay_lag FROM pg_stat_replication;
```

`confirmed_flush_lsn`은 연속이 아니라 **계단식으로** 전진합니다. 소비자가 배치를
다운스트림에 넣은 뒤에 확인하기 때문입니다 — 5초 보고 멈췄다고 판단하지 마세요.
실측: 1,492행을 넣자 미소비 WAL이 36 MB까지 올랐다가 30초 안에 0이 됐습니다.

두 가지를 지켜보세요. **비활성 슬롯은 WAL을 무한정 붙들어** 디스크를 채웁니다.
`SELECT count(*) FROM pg_replication_slots WHERE NOT active`를 모니터링에 넣으
세요. 그리고 여기 퍼블리케이션은 테이블을 명시적으로 지정합니다 —
`FOR ALL TABLES`였다면 스크래치 테이블까지 딸려갔을 것이고, 그래서
`stream-trips.sh`는 종료 시 표본 테이블을 지웁니다.

### 여기서 멈추는 이유

위 집계는 Postgres에서 164만 행을 훑습니다. 바로 그 일이 ClickHouse에 맞는
작업입니다 — `bike.trips`를 외래 테이블 뒤에 두고, 집계된 결과만 돌아와
`bike.stations`와 조인하는 형태.

그 배선은 여기 없습니다. 다만 하기 전에 알아둘 것 두 가지: **FDW는 Postgres
서버에서 바깥으로 연결합니다.** AWS의 관리형 서비스에서 노트북의 ClickHouse는
닿지 않으니, 서비스가 접속할 수 있는 곳에 있어야 합니다. 그리고 PostGIS
지오메트리 타입은 ClickHouse에 대응물이 없어 **공간 조건은 푸시다운되지
않습니다.** 경계는 정수 대여소번호에 두세요.

### 원본에 대한 참고

포털은 평범한 POST로 파일을 내려주는데, 파일별 내부 sequence 번호와 데이터셋별
`infSeq`로 식별합니다. 조회 수단이 없어 `fetch-data.sh`에 값을 박아두었습니다.
`infSeq`가 틀리면 오류가 나지 않고 **다른 데이터셋의 파일이 내려옵니다.** 이걸
만들면서 첫 시도에 무관한 1 GB 바이너리를 받았습니다. 스크립트가 응답의 파일명을
검사해 예상과 다르면 거부합니다.

CSV 인코딩은 CP949입니다.

### 📄 라이선스

[MIT](../../LICENSE) — 저장소 전체와 동일합니다. 데이터는 여기 재배포하지
않습니다. `fetch-data.sh`가 서울 열린데이터광장(공공누리 제1유형)에서 직접
받아오며 `data/`는 gitignore됩니다.
