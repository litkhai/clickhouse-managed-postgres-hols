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

### The tables

`bike.stations` mirrors the spreadsheet and adds `geom geometry(Point, 4326)`,
built from the published lat/lon. `bike.trips` keeps all sixteen source columns
in their original order, so a ClickHouse table can mirror it one-for-one when
the fact side moves.

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

### 테이블

`bike.stations`는 원본 스프레드시트를 그대로 옮기고 공개된 위경도로
`geom geometry(Point, 4326)`을 만듭니다. `bike.trips`는 원본 16개 컬럼을 순서
그대로 유지합니다 — 팩트 쪽을 옮길 때 ClickHouse 테이블이 1:1로 대응되도록.

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
