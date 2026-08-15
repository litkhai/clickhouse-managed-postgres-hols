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
| `stream-trips.sh` | Continuous insert in the same shape — `--rate`, `--interval`, `--batches` |
| `psql.sh` | psql against the service; `-f /sql/02-verify.sql` for the checks |

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

### Streaming inserts

`stream-trips.sh` samples real origin–destination pairs out of the loaded
history and re-inserts them with current timestamps. Origin–destination flow
here is heavily skewed — a few stations near river crossings and campuses carry
a disproportionate share, and duration tracks the pair — so inventing pairs
uniformly would produce a table that aggregates into a shape the real one never
takes. Only the timestamps are new.

```
$ ./scripts/stream-trips.sh --rate 500 --interval 1 --batches 5
  drew 50000 real trip shapes to sample from
  batch 5          2486 trips inserted
stopped after 5 batches, 2486 trips in 6s
average 414 trips/s
```

A batch lands slightly under `--rate` because duplicate draws collapse; the
count reported is what the insert returned, not what was asked for.

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
| `stream-trips.sh` | 동일 포맷으로 지속 삽입 — `--rate`, `--interval`, `--batches` |
| `psql.sh` | 서비스에 psql 접속; 점검은 `-f /sql/02-verify.sql` |

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

### 스트리밍 삽입

`stream-trips.sh`는 적재된 이력에서 실제 출발–도착 쌍을 표본으로 뽑아 현재
시각으로 다시 넣습니다. 이 데이터의 OD 흐름은 편중이 심해서 — 한강 다리 근처와
대학가 몇 곳이 큰 비중을 차지하고, 소요시간도 쌍에 따라갑니다 — 쌍을 균등하게
지어내면 실제로는 나오지 않는 모양으로 집계됩니다. 새로 만드는 건 타임스탬프뿐
입니다.

배치는 `--rate`보다 조금 적게 들어갑니다(중복 추출이 합쳐져서). 출력되는 수는
요청한 수가 아니라 삽입이 반환한 실제 행 수입니다.

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
