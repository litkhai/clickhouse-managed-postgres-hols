# The demo in one minute

[English](#english) | [한국어](#한국어)

## English

**Claim:** you do not have to choose between Postgres and ClickHouse. Keep the
geography in Postgres, send only the counting to ClickHouse, and neither side
does the thing it is bad at.

**Data:** Seoul's public bike system, real open data.

```
bike.stations   2,789 rows, PostGIS points      ← barely changes
bike.trips      1.6M rows per month             ← grows forever, only ever counted
                joined on an integer station id
```

That join key is the whole trick. It is an integer, so no geometry ever has to
reach the aggregating side.

**Shape:**

```
   PostGIS (local only)      pg_clickhouse (FDW)        ClickHouse
   ────────────────────      ───────────────────        ──────────
   geometry: geom            small result comes back ←  trips + stations
   Voronoi, KNN, DBSCAN,                                GROUP BY *and* the
   ST_Distance, azimuth                                 join both run here
```

ClickPipes replicates **both** `bike.trips` and `bike.stations`, and
pg_clickhouse pushes down joins between tables on the same remote server — so
naming a station is remote work too. What cannot move is the geometry: `geom`
has no ClickHouse equivalent. What breaks pushdown is mixing in a *local*
table.

**Two things to show:**

1. `sql/10-spatial-postgres.sql` — five queries that *cannot* move. Voronoi
   service areas, nearest neighbours through the GiST index, DBSCAN clusters,
   detour factor against the geodesic, net flow and its bearing.
2. `sql/20-aggregate-pushdown.sql` — five that *should* move. Nothing but
   `WHERE`, `GROUP BY`, `HAVING` and plain aggregates over millions of rows.

**Prove the second half actually moved:**

```bash
./scripts/explain-pushdown.sh
```

`EXPLAIN (VERBOSE)` prints the SQL the wrapper will send. If `Remote SQL`
carries the `GROUP BY`, ClickHouse did the work. If it only selects columns and
there is an `Aggregate` above it, every row crossed the network and Postgres
counted them — slower than never moving the table. Nothing warns you about
this; you have to look.

**Run it:**

```bash
ln -s ../provisioning/config.env config.env
./scripts/fetch-data.sh        # real open data, no API key
./scripts/load-stations.sh     # geometry
./scripts/load-trips.sh        # one real month
./scripts/backfill-trips.sh    # fill every missing day since
./scripts/generate-trips.sh    # keep it live
```

**Or watch it happen:**

```bash
./scripts/psql.sh -v ch_host=... -v ch_pass=... -f /sql/40-fdw-clickhouse.sql
cd ui && docker compose --env-file ../config.env up --build   # localhost:8080
```

The Pushdown tab runs the same query on both sides at once. Measured against a
28-day window of 24M rows:

| | plan | rows it moved | time |
|---|---|---|---|
| Postgres, local tables | 10 nodes — hash join, sort, aggregate | 3,459,577 through the sort | 9.6 s |
| ClickHouse, foreign tables | **one Foreign Scan** | 15 rows back | 1.3 s |

ClickHouse's own `system.query_log` agrees, which is the part that settles it:
24.11M rows read *there*, 15 rows returned. The join went with the aggregate —
both tables are remote, which is the whole reason `bike.stations` is replicated
too.

Full detail in [README.md](README.md); how the Postgres half was built in
[WRITEUP.md](WRITEUP.md), and the ClickHouse half and the dashboard in
[WRITEUP-UI.md](WRITEUP-UI.md).

---

## 한국어

**주장:** Postgres냐 ClickHouse냐를 고를 필요가 없습니다. 지리는 Postgres에
두고 집계만 ClickHouse로 보내면, 양쪽 모두 잘 못하는 일을 하지 않습니다.

**데이터:** 서울 공공자전거(따릉이) 실제 공개 데이터.

```
bike.stations   2,789행, PostGIS 포인트   ← 거의 안 변함
bike.trips      월 164만 행               ← 무한히 늘고, 집계만 함
                정수 대여소번호로 조인
```

조인 키가 정수라는 게 핵심입니다. 지오메트리가 집계하는 쪽으로 건너갈 일이
없습니다.

**구조:**

```
   PostGIS (로컬 전용)       pg_clickhouse (FDW)      ClickHouse
   ─────────────────────     ───────────────────      ──────────
   지오메트리: geom          작은 결과만 회수    ←    trips + stations
   Voronoi, KNN, DBSCAN,                              GROUP BY 도 조인도
   ST_Distance, 방위각                                여기서 실행
```

ClickPipes가 `bike.trips`와 `bike.stations`를 **둘 다** 복제하고,
pg_clickhouse는 같은 원격 서버의 테이블끼리 조인도 푸시다운합니다 — 대여소
이름을 붙이는 것도 원격 작업입니다. 옮길 수 없는 건 지오메트리입니다: `geom`에는
ClickHouse 대응물이 없습니다. 푸시다운을 깨는 건 **로컬** 테이블을 섞는 것입니다.

**보여줄 것 두 가지:**

1. `sql/10-spatial-postgres.sql` — 옮길 수 *없는* 쿼리 5개. Voronoi 세력권,
   GiST 최근접, DBSCAN 군집, 측지선 대비 우회율, 순유출입과 방위.
2. `sql/20-aggregate-pushdown.sql` — 옮겨야 *하는* 쿼리 5개. 수백만 행에 대해
   `WHERE`·`GROUP BY`·`HAVING`과 기본 집계만 씁니다.

**후자가 실제로 넘어갔는지 증명:**

```bash
./scripts/explain-pushdown.sh
```

`EXPLAIN (VERBOSE)`는 래퍼가 보낼 SQL을 출력합니다. `Remote SQL`에 `GROUP BY`가
있으면 ClickHouse가 처리한 것입니다. 컬럼만 뽑고 위에 `Aggregate`가 있으면 모든
행이 네트워크를 건너와 Postgres가 센 것이며, 테이블을 옮기지 않느니만 못합니다.
**아무도 경고해 주지 않으니 직접 봐야 합니다.**

**실행:**

```bash
ln -s ../provisioning/config.env config.env
./scripts/fetch-data.sh        # 실제 공개 데이터, API 키 불필요
./scripts/load-stations.sh     # 지오메트리
./scripts/load-trips.sh        # 실제 한 달
./scripts/backfill-trips.sh    # 이후 빠진 날짜 전부 채움
./scripts/generate-trips.sh    # 계속 흘려보냄
```

**직접 보려면:**

```bash
./scripts/psql.sh -v ch_host=... -v ch_pass=... -f /sql/40-fdw-clickhouse.sql
cd ui && docker compose --env-file ../config.env up --build   # localhost:8080
```

Pushdown 탭이 같은 쿼리를 양쪽에서 동시에 돌립니다. 2,400만 행 중 28일 구간
측정값:

| | 플랜 | 옮긴 행 | 시간 |
|---|---|---|---|
| Postgres, 로컬 테이블 | 노드 10개 — 해시 조인·정렬·집계 | 정렬을 통과한 3,459,577행 | 9.6초 |
| ClickHouse, foreign table | **Foreign Scan 하나** | 회수 15행 | 1.3초 |

결정적인 건 ClickHouse 자신의 `system.query_log`도 같은 말을 한다는 것입니다:
*저쪽에서* 24.11M 행을 읽고 15행을 돌려줬습니다. 조인도 집계와 함께 갔습니다 —
두 테이블이 모두 원격이기 때문이고, `bike.stations`까지 복제하는 이유가 바로
이것입니다.

자세한 내용은 [README.md](README.md), Postgres 절반을 만든 과정은
[WRITEUP.md](WRITEUP.md), ClickHouse 쪽과 대시보드는
[WRITEUP-UI.md](WRITEUP-UI.md).
