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
   PostGIS                  pg_clickhouse (FDW)              ClickHouse
   ───────                  ───────────────────              ──────────
   2,789 station points  ←  small aggregate comes back  ←    22M+ trips
   Voronoi, KNN, DBSCAN,    joined locally on                GROUP BY runs here
   ST_Distance, azimuth     station_id
```

ClickPipes replicates `bike.trips` into ClickHouse continuously; the foreign
table points back at it.

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

Full detail in [README.md](README.md).

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
   PostGIS                  pg_clickhouse (FDW)         ClickHouse
   ───────                  ───────────────────         ──────────
   대여소 2,789개 포인트  ←  작은 집계 결과만 회수  ←   2,200만+ 대여
   Voronoi, KNN, DBSCAN,     station_id 로                GROUP BY 는
   ST_Distance, 방위각       로컬 조인                    여기서 실행
```

ClickPipes가 `bike.trips`를 ClickHouse로 계속 복제하고, 외래 테이블이 그것을
가리킵니다.

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

자세한 내용은 [README.md](README.md).
