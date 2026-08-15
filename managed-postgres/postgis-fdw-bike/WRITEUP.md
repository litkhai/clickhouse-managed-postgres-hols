# How this demo was built

What the demo argues, where the data came from, which decisions were forced by
the platform, and what happened when the claim was finally tested. Numbers were
measured on a live ClickHouse Managed Postgres service in `ap-northeast-2`,
August 2026. Mistakes are left in — they are the part worth reading.

For how to run it, see [README.md](README.md).

[English](#english) | [한국어](#한국어)

---

## English

### 1. The argument

Analytics teams are told to pick: keep the operational database and accept slow
aggregates, or move to a column store and lose everything the operational
database was good at. For spatial workloads that choice is unusually painful,
because the thing you lose — PostGIS — has no column-store equivalent worth the
name.

The claim here is that the choice is false, provided the boundary is drawn in
the right place. Keep the geometry where PostGIS is. Send the counting where
ClickHouse is. Join on an integer, so no geometry ever has to cross.

The demo's job is to make that boundary visible, and then to prove the traffic
actually crosses it.

### 2. Choosing the data

Seoul's public bike history has the shape the argument needs, without
contrivance:

| Side | What it holds | Size |
|------|---------------|------|
| **PostGIS** | 대여소 — station points, districts, addresses | 2,789 rows, static |
| **Facts** | 대여이력 — one row per trip | ~1.6M rows *per month* |

One side is small, geographic and almost unchanging. The other grows without
bound and is only ever counted. They join on a station number — an integer.

That integer is the whole trick. If the join key were a geometry, the
aggregating side would need geometry, and there would be no boundary to draw.

Both datasets are 서울 열린데이터광장 open data under **공공누리 제1유형**:
attribution, commercial use and modification allowed. No API key, no account.

**The portal is a trap worth documenting.** Files come over a plain POST keyed
by an internal sequence number per file plus an `infSeq` per dataset, and the
portal exposes no lookup for either. Get `infSeq` wrong and it does not error —
it serves *a different dataset's file*. The first attempt pulled down an
unrelated 1 GB binary. `fetch-data.sh` pins the numbers and checks the filename
in the response before keeping anything.

### 3. What the platform gave us

Checked on the running service rather than assumed:

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

One version string causes confusion and is worth defusing:
`PostgreSQL 18.4 (Ubuntu 18.4-1.pgdg22.04+1)`. The `Ubuntu 18.4-1` is the Debian
package version of Postgres 18.4, not Ubuntu 18.04. The OS is the `pgdg22.04`
at the end — Ubuntu 22.04.

### 4. The one decision worth arguing about: UTC

The trip data is published in Korean local time. The column is
`timestamp without time zone`. Nothing anywhere records which zone the numbers
are in.

That is survivable inside Postgres and dangerous the moment ClickHouse is
involved, because **ClickHouse attaches a timezone to `DateTime`** and Postgres
does not. The same wall-clock number means two different instants on the two
sides. Hourly aggregates come out shifted by nine hours, and nothing errors.

So the table stores **UTC**: `shift-to-utc.sh` converted the existing rows once,
`load-trips.sh` subtracts nine hours on the way in, and both generators stamp
UTC. Korea has no daylight saving, so the offset is a constant nine hours and
the conversion is a subtraction rather than a zone-aware cast.

The visible consequence: the weekday commute peaks now sit at **23:00 and 09:00
UTC**. Everything a reader sees converts back to Seoul time, and the schema says
UTC in a comment on the column, because the type cannot.

**The conversion had to be batched.** One `UPDATE` over 23.8M rows rewrites
every tuple in a single transaction: the table roughly doubles before autovacuum
can reclaim anything, and around 20 GB of WAL is pinned until commit. Walking
the primary key in 250k-row batches keeps dead tuples collectable and WAL
drainable as it goes — 689 seconds for 23,870,900 rows. Progress is bookmarked
in a table rather than inferred, because a converted row is indistinguishable
from one that never needed converting; resuming by timestamp would silently
shift some rows twice.

Getting this wrong is silent. The in-database generator first read
`AT TIME ZONE 'Asia/Seoul'` while the table was still KST and generated the
07:00 shape at 16:45. The rows looked entirely plausible.

### 5. Building a dataset that behaves like the real one

One real month is 1.6M trips. A demo wants more, and it wants *today* to have
data. Three pieces: January 2026 loaded as published (1,646,600 trips);
`backfill-trips.sh` filling the 195 days with no rows (22.2M trips at real
volume); and a pg_cron job inserting, every minute, however many trips this hour
of this weekday calls for. Total: **24,037,356 trips across 228 days**, 7.1 GB.

**Backfill asks the database which days are empty** rather than starting from
`max(started_at) + 1`. The simpler version was wrong: a streaming test had
already put rows on today's date, which made February through August look
covered.

#### How the synthetic trips are made, and why

The tempting approach is to sample each column from its own distribution. It
produces a table where every histogram is right and every relationship is gone.
Here that would be fatal: morning trips run to subway stations and last eight
minutes, Sunday afternoon trips run along the river and last forty, rider age
shifts with both, and the OD matrix is extremely skewed. Sample independently
and the OD matrix goes uniform, which flattens exactly the aggregates the demo
exists to show.

So a generated trip is **a real trip with a new timestamp**, drawn from the pool
of real trips that started in the *same hour of the same kind of day*. Only
volume and timestamps are synthetic; duration gets ±20% jitter, and distance
scales with it so the implied speed stays plausible.

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
2026-01 to 06, so June is 2.56× January), and July onward is extrapolated.
`--explain` names the guessed months rather than hiding them.

**Arrivals are drawn from a Poisson.** A fixed rate makes every window return
the identical count, and a live feed that ticks like a metronome is obviously
fake at a glance.

One honest limit: sampling every *n*th trip misses the rarest stations, so a
generated week covered 2,541 of the 2,768 origin stations.

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

**Only two tables should replicate.** The generator's working tables live in a
separate `bikegen` schema, so a publication declared `FOR ALL TABLES` cannot
sweep them into ClickHouse. The `bike` schema holds exactly `trips` and
`stations`.

**Two things to monitor.** `confirmed_flush_lsn` advances in steps, not
continuously, because the consumer confirms once a batch has landed downstream —
watching it for five seconds and concluding it has stalled is a mistake. And an
**inactive slot retains WAL indefinitely**: one bulk load arriving as a single
22M-row transaction was enough to disconnect the consumer, after which the slot
sat holding 13 GB. `SELECT count(*) FROM pg_replication_slots WHERE NOT active`
belongs in whatever you monitor.

### 7. The query split

Ten queries, in two files, chosen so the boundary is visible.

**`sql/10-spatial-postgres.sql` — cannot move.** Voronoi service areas clipped
to the network hull; five nearest neighbours per station through the GiST index
and the `<->` operator; DBSCAN clusters that straddle administrative boundaries;
detour factor comparing recorded distance to the geodesic; net flow per district
with its mean bearing.

That last one is worth a paragraph. Bearings are circular, so averaging them
arithmetically makes 350° and 10° come out as 180° — the exact opposite of the
truth. Because flows are roughly symmetric, the naive version reported a
confident "south" for all 25 districts. Summing unit vectors and taking `atan2`
gives the real mean, and the length of the resultant says whether there is a
dominant direction at all: two districts turn out to have none, and the query
says so instead of inventing one.

**`sql/20-aggregate-pushdown.sql` — should move.** Which stations are commuter
stations rather than leisure stations; the heaviest corridors end to end; where
rebalancing vans are needed; how each district rides; when each district wakes
up.

The instinct is to keep the station join in Postgres and let only the counting
travel. That is wrong here, and the documentation is explicit:

> *pg_clickhouse also pushes down JOINs to tables that are from the same remote
> server.*
>
> *Joining with a local table will generate less efficient queries without
> careful tuning.*

Since ClickPipes replicates `stations` too, naming a station or grouping by
district is remote work like everything else. **What breaks pushdown is mixing
in a local table, not joining as such.**

### 8. Replication is not pushdown

At this point the lab asserted that the aggregates belong on ClickHouse and
stopped. Wiring the other direction turned up the distinction that matters most,
and it is one the first version of the UI got wrong.

```
pg_extension        plpgsql, pg_stat_ch, postgis, pg_clickhouse, pg_cron
pg_foreign_server   0
foreign_tables      0
ClickHouse pg_sync  bike_trips 24,063,550 rows / bike_stations 2,789 rows
```

ClickPipes was working perfectly. Postgres held 24,062,759 rows and ClickHouse
24,063,550 — seconds apart, with the generator's rows still arriving. And there
were no foreign tables at all.

```
ClickPipes / PeerDB    Postgres ──replicate──▶ ClickHouse    (was working)
pg_clickhouse (FDW)    Postgres ◀────query──── ClickHouse    (did not exist)
```

Pushdown needs the second. No amount of the first creates a way for Postgres to
read back out. Conflating them is the easiest way to believe a query moved when
it never did — and a badge reading "ran on Postgres" for a plan that had nowhere
else to send the work reads as a *failed* pushdown rather than a missing one.
That distinction drove the verdict engine in §10.

**Ask the wrapper what options it takes**, rather than guessing:

```sql
CREATE SERVER probe FOREIGN DATA WRAPPER clickhouse_fdw OPTIONS (bogus 'x');
-- ERROR:  invalid option "bogus"
-- HINT:   Valid options in this context are:
--         host, secure, min_tls_version, port, dbname, compression, driver, fetch_size
```

**The foreign tables are declared, not imported.** ClickPipes names them
`bike_trips` and `bike_stations`, but the point of the lab is that the *same
query text* runs against either side. `table_name` does the renaming, so
`{schema}.trips` needs only `bike` ↔ `ch` swapped:

```sql
CREATE FOREIGN TABLE ch.trips (...) SERVER chsrv OPTIONS (table_name 'bike_trips');
```

The PeerDB bookkeeping columns are deliberately left out: they are not part of
the model, and a column the query never mentions is one less thing to translate.

### 9. What actually moves, measured

Pushdown is all-or-nothing, in two steps. First the planner will only build a
foreign join if **every** relation in it lives on the same foreign server — one
local table and the join stays local. Only then will it consider putting the
grouping on top, and only if every aggregate, `GROUP BY` expression and
`HAVING` clause is something the wrapper can translate. Miss either and nothing
partial happens: the whole aggregate falls back and the base rows cross the
network.

When it works, the plan is one node:

```
Foreign Scan
  Relations: Aggregate on ((trips t) INNER JOIN (stations s))
  Remote SQL: SELECT r2.district, count(*), round(avg(r1.duration_min), 1)
              FROM pg_sync.bike_trips r1
              ALL INNER JOIN pg_sync.bike_stations r2
                ON (r1.start_station_id = r2.station_id)
              GROUP BY r2.district ORDER BY count(*) DESC NULLS FIRST
```

The KST filters generate `extract(hour FROM started_at + interval '9 hours')`,
and the expectation was that expressions like that would break pushdown — enough
that rewriting the queries into a more pushdown-friendly shape was considered.
**That was wrong.** Left exactly as written, all five aggregates move, over a
28-day window:

| Query | local (`bike`) | remote (`ch`) |
|---|---|---|
| By district | 8,793 ms | 1,874 ms |
| Corridors | 6,957 ms | 2,159 ms |
| Commute vs leisure | 3,219 ms | 1,530 ms |
| Hour of day | 7,375 ms | 1,099 ms |
| Over time | 3,558 ms | 3,830 ms |

The time-zone arithmetic translates cleanly:

```
extract(hour FROM started_at + interval '9 hours')      →  toHour(started_at + 32400)
date_trunc('quarter', started_at + interval '9 hours')  →  toStartOfQuarter(started_at + 32400)
```

All five bucket sizes push down too, and the read side stays constant while the
returned side shrinks — the cheap half of a rollup:

| Bucket | local | remote | rows back |
|---|---|---|---|
| 1 hour | 2,631 ms | 1,742 ms | 15 |
| 24 hours | 3,927 ms | 1,610 ms | 15 |
| 1 week | 5,285 ms | 1,169 ms | 5 |
| 1 month | 5,081 ms | 1,667 ms | 2 |
| 1 quarter | 5,082 ms | 1,602 ms | 1 |

**A Postgres plan claiming the work went remote is not evidence.** ClickHouse
was asked directly:

```
11:44:30  1483 ms  read 24.11 million rows / 551 MiB  →  result_rows 15
          SELECT r2.district, r2.name, count(*), … cast(toHour((r1.started_at + 32400)) …
11:39:39  1563 ms  read 24.11 million rows / 735 MiB  →  result_rows 1
          SELECT toStartOfQuarter((r1.started_at + 32400)), count(*), …
```

What settles it is **where the 24M rows were read**. They were read there, and
15 came back.

**A finding that is not flattering.** ClickHouse reads all 24.11M rows even for
a 28-day filter, because `started_at` is not the sorting key and nothing prunes.
On short ranges that makes local *faster* — a 2-day window is 1,101 ms locally
against 2,078 ms remotely. The UI does not hide it.

### 10. Reading the plan honestly

The first verdict engine matched plan text for `Remote SQL` and `GROUP BY`. That
cannot distinguish three different outcomes:

1. the aggregate was sent (`pushed`),
2. the rows were dragged back and counted here (`dragged`),
3. there was no foreign table in the plan at all (`no_fdw`).

Walking `EXPLAIN (FORMAT JSON)` as a tree can. It finds the `Foreign Scan` nodes,
reads their `Remote SQL` and row counts, and checks what aggregation is left
above them.

**`COSTS OFF` was a trap.** With it, "how many rows crossed" came back as zero
every time — because `COSTS OFF` removes `Plan Rows` along with the costs, and
that number is the entire point of the screen. Costs are never displayed, but
`COSTS` stays on.

**Estimates and measurements are labelled differently.** Without `ANALYZE` the
counts are the planner's guesses; with it they are what happened, at the price
of running the query twice. So it is a checkbox, not the default:

```
                            estimated               measured with ANALYZE
local   Limit→Sort→Aggregate→Sort→Hash Join         3,459,577 rows through   9,639 ms
remote  Foreign Scan                                15 rows fetched          1,329 ms
```

The widest node in the plan is tracked separately from the rows that crossed,
because "15 rows came back" says nothing about what the other side had to do to
avoid needing them.

### 11. What the dashboard forced

**A 14-second query was being polled every 15 seconds.** The first overview
endpoint ran `count(DISTINCT started_at::date)` on a timer; that query takes
14.3 s at this row count, so it was effectively never not running. Measured
costs at 24M rows:

| Query | Time |
|---|---|
| `min/max(started_at)` | 15 ms (index) |
| last 60 minutes by minute | 18 ms (index) |
| `count(*)` | 1.0 s |
| full daily rollup | 5.1 s |
| `count(DISTINCT started_at::date)` | **14.3 s** |

Splitting the endpoint in two follows from that: a pulse that is index-only work
at ~200 ms and can be polled, and everything that scans behind a **Run** button.
Which is also the more honest demo — you can see which questions are expensive
while the facts are still in Postgres.

**Ranges are presets, and the bucket depends on the range.** A quarter bucket
over one day is a single bar; an hour bucket over a year is a solid block. Only
buckets that divide the range into 2–800 points are offered, and the range is
counted back from the newest trip rather than from today, because the data ends
where the generator last wrote.

**Client-side binding, deliberately.** `ClientCursor` means the SQL on screen is
the text that ran rather than a template with `$1` in it — and, more usefully, a
parameterised query reaches a foreign table as a generic plan with placeholders.
A wrapper that cannot see the constants has less to push down.

**The palette was computed, not chosen.** Blue already meant Postgres and yellow
already meant ClickHouse, so the data series needed different hues. Dropping
those two from a validated categorical order and keeping the rest failed the
check outright — magenta ended up adjacent to aqua at CVD ΔE 1.6, effectively
the same colour for a red-green colourblind reader. Adjacent-pair validation
only holds for the order it was validated in. Three slots, re-validated
all-pairs, pass at 9.4.

**Blind truncation makes wrong labels, not short ones.** `slice(-5)` shortened
dates nicely and turned the duration bucket `90–105` into `0–105`.

**The copy was saying everything twice.** A badge reading "ClickHouse" followed
by a sentence explaining that ClickHouse did the counting, beside a table
already showing the row counts. The screen states facts; the explanations live
in the About tab.

### 12. Numbers worth quoting

| | |
|---|---|
| Stations | 2,789 across 25 districts |
| Trips | 24,037,356 over 228 days |
| Table size | 7.1 GB (256 bytes per row including indexes) |
| WAL generated | 811 bytes per row |
| Real month load | 1.64M rows in 53s via COPY |
| UTC conversion | 23.87M rows in 689s, 250k-row batches |
| Add primary key | 7.7s over 1.64M rows |
| Live feed | ~480 trips per 5 minutes at an off-peak hour |
| Pushdown, 28-day window | 9,639 ms local → 1,329 ms remote |
| Plan nodes | 10 local → 1 remote |
| Rows moved | 3,459,577 through a sort locally; 15 fetched remotely |
| Confirmed on the ClickHouse side | `system.query_log`: 24.11M read, 15 returned |
| Pulse endpoint | 204–235 ms, replacing a 14.3 s query on a 15 s timer |
| Short-range reversal | 2-day window: 1,101 ms local vs 2,078 ms remote |

### 13. What is left

- **ClickHouse's sorting key.** `started_at` is not it, so a range filter prunes
  nothing and all 24.11M rows are read whatever the window. Fixing that would
  widen the gap considerably, and would remove the short-range reversal above.
- **`geom` replicates as `String`.** ClickHouse has no geometry type, so the
  foreign table maps it to `text` and no query selects it. The replica exists so
  the *join* can happen remotely, not so geometry can travel.
- **Row estimates are poor.** `clickhouse_fdw` estimates a foreign scan at 1 row
  where the answer is 15. It did not change any plan choice here, but it is why
  the page labels unmeasured counts as estimates.

---

## 한국어

### 1. 주장

분석 팀은 둘 중 하나를 고르라는 말을 듣습니다. 운영 DB를 유지하고 느린 집계를
감수하든지, 컬럼 스토어로 옮기고 운영 DB가 잘하던 것을 전부 잃든지. 공간
워크로드에서는 이 선택이 유난히 아픕니다. 잃게 되는 것 — PostGIS — 에 쓸 만한
컬럼 스토어 대응물이 없기 때문입니다.

이 랩의 주장은 경계를 제자리에 그으면 그 선택이 거짓이라는 것입니다. 지오메트리는
PostGIS가 있는 곳에 둡니다. 세는 일은 ClickHouse가 있는 곳으로 보냅니다. 정수로
조인해서 지오메트리가 건너갈 일을 없앱니다.

데모가 할 일은 그 경계를 눈에 보이게 만들고, 트래픽이 실제로 그 경계를 넘는지
증명하는 것입니다.

### 2. 데이터 선정

서울 따릉이 대여이력은 억지 없이 이 구조를 갖고 있습니다.

| 쪽 | 담는 것 | 크기 |
|---|---|---|
| **PostGIS** | 대여소 — 포인트, 자치구, 주소 | 2,789행, 정적 |
| **팩트** | 대여이력 — 대여 한 건이 한 행 | **월** 164만 행 |

한쪽은 작고 지리적이며 거의 변하지 않습니다. 다른 쪽은 무한히 늘고 집계만
됩니다. 둘은 대여소번호 — 정수 — 로 조인됩니다.

그 정수가 핵심입니다. 조인 키가 지오메트리였다면 집계하는 쪽도 지오메트리를
알아야 하고, 그러면 그을 경계 자체가 없습니다.

두 데이터셋 모두 서울 열린데이터광장 공개 데이터, **공공누리 제1유형**입니다 —
출처 표시 후 상업적 이용과 변형 가능. API 키도 계정도 필요 없습니다.

**포털에는 기록해 둘 만한 함정이 있습니다.** 파일은 평범한 POST로 받는데, 파일별
내부 시퀀스 번호와 데이터셋별 `infSeq`로 식별되고 포털은 둘 다 조회 수단을
제공하지 않습니다. `infSeq`를 틀리면 에러가 나지 않고 **다른 데이터셋의 파일**을
줍니다. 첫 시도에서 관계없는 1 GB 바이너리를 받았습니다. `fetch-data.sh`는 번호를
고정하고 응답의 파일명을 확인한 뒤에만 저장합니다.

### 3. 플랫폼이 제공한 것

가정하지 않고 running 서비스에서 확인한 것:

```
PostgreSQL 18.4 (aarch64)          TLS 1.3 강제, 평문 거부
postgis 3.6.4                      h3 4.2.3, h3_postgis, postgis_raster,
                                   postgis_topology, postgis_sfcgal 도 함께
pg_clickhouse 0.3                  FDW — 사용 가능, 기본 설치는 아님
pg_cron 1.6                        이미 shared_preload_libraries 에 있음
pg_stat_ch 0.3                     기본 설치됨
wal_level = logical                기본값. CDC 켜는 데 재시작 불필요
확장 101개 사용 가능
```

이 중 셋이 데모를 결정했습니다.

- **PostGIS가 진짜 3.6.4**입니다. 축소판이 아니라 Voronoi·DBSCAN·geography 거리가
  전부 동작합니다.
- **`wal_level`이 이미 `logical`**이라 ClickPipes에 Postgres 쪽 설정 변경이
  필요 없습니다.
- **`pg_cron`이 preload되어 있어** 서버 사이드 생성기가 가능합니다. 노트북을 닫아도
  데모가 계속 돕니다.

헷갈리는 버전 문자열 하나는 짚고 갈 만합니다:
`PostgreSQL 18.4 (Ubuntu 18.4-1.pgdg22.04+1)`. 여기서 `Ubuntu 18.4-1`은 우분투
18.04가 아니라 Postgres 18.4의 데비안 패키지 버전입니다. OS는 뒤의 `pgdg22.04`
— Ubuntu 22.04입니다.

### 4. 논쟁할 만한 결정 하나: UTC

대여 데이터는 한국 지역시로 발행되고, 컬럼은 `timestamp without time zone`이며,
어디에도 어느 존인지 기록되어 있지 않습니다.

Postgres 안에서는 버틸 만하지만 ClickHouse가 끼는 순간 위험해집니다. **ClickHouse는
`DateTime`에 타임존을 붙이고** Postgres는 붙이지 않기 때문입니다. 같은 벽시계
숫자가 양쪽에서 다른 시점을 뜻하게 됩니다. 시간별 집계가 아홉 시간 밀리는데,
아무 에러도 나지 않습니다.

그래서 테이블은 **UTC**로 저장합니다. `shift-to-utc.sh`가 기존 행을 한 번
변환했고, `load-trips.sh`가 적재 시 아홉 시간을 빼고, 두 생성기 모두 UTC로
찍습니다. 한국은 서머타임이 없어 오프셋이 상수 9시간이라, 존 인식 캐스팅이 아니라
뺄셈이면 됩니다.

눈에 보이는 결과: 평일 출퇴근 피크가 **UTC 23:00과 09:00**에 있습니다. 사람이 보는
모든 값은 서울 시각으로 되돌리고, 타입이 말할 수 없으니 컬럼 주석에 UTC라고
적어 둡니다.

**변환은 배치로 해야 했습니다.** 2,380만 행에 `UPDATE` 한 번이면 모든 튜플을 한
트랜잭션에서 다시 씁니다. autovacuum이 회수하기 전에 테이블이 대략 두 배가 되고,
커밋까지 약 20 GB의 WAL이 묶입니다. 기본키를 25만 행 단위로 훑으면 진행하면서
데드 튜플이 회수되고 WAL이 빠집니다 — 23,870,900행에 689초. 진행 상황은 추론하지
않고 테이블에 북마크합니다. 변환된 행과 애초에 변환이 필요 없던 행은 구분할 수
없어서, 타임스탬프로 재개하면 일부 행이 조용히 두 번 밀립니다.

이걸 틀리면 조용합니다. DB 내장 생성기가 테이블이 아직 KST일 때
`AT TIME ZONE 'Asia/Seoul'`을 읽어 16:45에 07:00의 모양을 생성했습니다. 행들은
아주 그럴듯해 보였습니다.

### 5. 실제처럼 움직이는 데이터셋 만들기

실제 한 달은 164만 건입니다. 데모는 더 많은 데이터를 원하고, **오늘** 데이터가
있기를 원합니다. 세 조각입니다. 2026년 1월을 공개된 그대로 적재(1,646,600건),
`backfill-trips.sh`로 행이 없는 195일을 채우기(실제 규모로 2,220만 건), 그리고
pg_cron 잡이 매분 이 요일·이 시각에 맞는 만큼 삽입. 합계 **228일간
24,037,356건**, 7.1 GB.

**백필은 `max(started_at) + 1`이 아니라 DB에 어느 날이 비었는지 묻습니다.** 더
간단한 쪽이 틀렸습니다 — 스트리밍 테스트가 이미 오늘 날짜에 행을 넣어 둬서 2월부터
8월까지가 채워진 것처럼 보였습니다.

#### 합성 대여를 만드는 방법과 이유

솔깃한 방법은 컬럼마다 자기 분포에서 뽑는 것입니다. 모든 히스토그램이 맞고 모든
관계가 사라진 테이블이 나옵니다. 여기서는 치명적입니다. 아침 대여는 지하철역으로
가고 8분이 걸리며, 일요일 오후 대여는 강변을 따라 40분이 걸리고, 이용자 연령도 둘
다에 따라 달라지며, OD 행렬은 극단적으로 치우쳐 있습니다. 독립적으로 뽑으면 OD
행렬이 균일해지고, 이 데모가 존재하는 이유인 바로 그 집계가 평평해집니다.

그래서 생성된 대여는 **새 타임스탬프를 가진 실제 대여**입니다. *같은 종류의 날,
같은 시각*에 출발한 실제 대여 풀에서 뽑습니다. 합성인 것은 양과 타임스탬프뿐이고,
이용시간에 ±20% 지터를 주며 거리는 거기에 비례해 조정해 속도가 그럴듯하게
남습니다.

실제 한 달과 비교한 측정값:

| | 실제 (1월) | 생성 |
|---|---|---|
| 평일 아침 피크 비중 | 28.16% | 28.20% |
| 저녁 피크 비중 | 26.55% | 26.49% |
| 평균 이용시간 | 17.1분 | 17.0분 |
| 평균 거리 | 1,724 m | 1,718 m |
| 왕복 비율 | 8.6% | 8.7% |

**무엇이 측정값이고 무엇이 가정인가.** 시간대 모양, 평일/주말 비율(하루 60,388
대 37,893), 대여 풀은 전부 측정값입니다. 월별 규모는 아닙니다 — 한 달만
적재했으니까요. 포털의 월별 파일 크기가 대여 건수를 대신하고(2026-01~06이 280,
307, 501, 674, 690, 716 MB이므로 6월은 1월의 2.56배), 7월 이후는 외삽입니다.
`--explain`이 추정한 달을 숨기지 않고 이름을 밝힙니다.

**도착은 푸아송에서 뽑습니다.** 고정 속도면 모든 구간이 똑같은 수를 돌려주는데,
메트로놈처럼 째깍대는 실시간 피드는 한눈에 가짜입니다.

정직한 한계 하나: *n*번째 대여마다 샘플링하면 가장 드문 대여소를 놓쳐서, 생성된
한 주가 2,768개 출발 대여소 중 2,541개를 덮었습니다.

### 6. 복제

ClickPipes가 `bike.trips`와 `bike.stations`를 ClickHouse로 복제합니다.

**기본키가 필요합니다.** ClickPipes는 replica identity가 없는 테이블을 거부합니다
— *"cannot be replicated because they don't have a valid replica identity"*.
대여 데이터에는 자연키가 없습니다. `bike_id`와 두 타임스탬프, 두 대여소번호를 다
써도 96행이 중복으로 남고, 그것들은 기록된 거리만 다른 진짜 별개의 대여입니다.
대리키 `bigint GENERATED ALWAYS AS IDENTITY`를 추가했고 164만 행에 7.7초
걸렸습니다. `REPLICA IDENTITY FULL`로도 에러는 없앨 수 있지만, 키는 ClickHouse
쪽에 정렬하고 중복 제거할 기준까지 줍니다.

**복제되어야 할 테이블은 둘뿐입니다.** 생성기의 작업 테이블은 별도 `bikegen`
스키마에 두어, `FOR ALL TABLES`로 선언된 publication이 그것들까지 쓸어 담지
못하게 했습니다. `bike` 스키마에는 정확히 `trips`와 `stations`만 있습니다.

**감시할 것 두 가지.** `confirmed_flush_lsn`은 연속이 아니라 계단식으로
전진합니다 — 소비자가 배치가 하류에 안착한 뒤에 확인하기 때문입니다. 5초 보고
멈췄다고 결론 내리는 것은 실수입니다. 그리고 **비활성 슬롯은 WAL을 무한히
붙잡습니다**. 2,200만 행짜리 단일 트랜잭션 대량 적재 한 번에 소비자가 끊겼고,
그 뒤 슬롯이 13 GB를 붙들고 있었습니다.
`SELECT count(*) FROM pg_replication_slots WHERE NOT active`는 모니터링에 넣을
가치가 있습니다.

### 7. 쿼리 분리

경계가 보이도록 고른 쿼리 열 개, 파일 두 개입니다.

**`sql/10-spatial-postgres.sql` — 옮길 수 없는 것.** 네트워크 외곽선으로 자른
Voronoi 세력권, GiST 인덱스와 `<->` 연산자를 쓴 대여소별 최근접 5개, 행정 경계를
가로지르는 DBSCAN 군집, 측지선 대비 우회율, 자치구별 순유출입과 평균 방위.

마지막 것은 한 문단 쓸 가치가 있습니다. 방위는 순환값이라 산술 평균을 내면 350°와
10°가 180°가 됩니다 — 정확히 반대입니다. 흐름이 대체로 대칭이라, 순진한 버전은 25개
자치구 전부에 대해 자신 있게 "남쪽"이라고 보고했습니다. 단위 벡터를 더해 `atan2`를
취하면 진짜 평균이 나오고, 결과 벡터의 길이가 지배적인 방향이 있기는 한지 말해
줍니다. 두 자치구는 없는 것으로 나오고, 쿼리는 지어내는 대신 그렇다고 말합니다.

**`sql/20-aggregate-pushdown.sql` — 옮겨야 하는 것.** 어느 대여소가 여가가 아니라
출퇴근 대여소인지, 가장 무거운 통행축은 어디에서 어디까지인지, 재배치 밴이 실제로
필요한 곳은 어디인지, 자치구별 이용 양상은 어떤지, 자치구마다 언제 깨어나는지.

본능적으로는 대여소 조인을 Postgres에 두고 세는 일만 보내고 싶어집니다. 여기서는
틀렸고, 문서가 명시적입니다.

> *pg_clickhouse also pushes down JOINs to tables that are from the same remote
> server.*
>
> *Joining with a local table will generate less efficient queries without
> careful tuning.*

ClickPipes가 `stations`도 복제하므로 대여소 이름을 붙이거나 자치구로 묶는 것도
다른 모든 것과 마찬가지로 원격 작업입니다. **푸시다운을 깨는 것은 조인 자체가
아니라 로컬 테이블을 섞는 것입니다.**

### 8. 복제가 된다고 푸시다운이 되는 게 아니다

여기까지 랩은 집계가 ClickHouse에 속한다고 주장한 채로 멈춰 있었습니다. 반대
방향을 붙이는 과정에서 가장 중요한 구분이 드러났고, 그건 UI의 첫 버전이 틀렸던
지점이기도 합니다.

```
pg_extension        plpgsql, pg_stat_ch, postgis, pg_clickhouse, pg_cron
pg_foreign_server   0
foreign_tables      0
ClickHouse pg_sync  bike_trips 24,063,550행 / bike_stations 2,789행
```

ClickPipes는 완벽하게 돌고 있었습니다. Postgres에 24,062,759행, ClickHouse에
24,063,550행 — 몇 초 차이이고 생성기의 행이 계속 도착하는 중이었습니다. 그리고
foreign table은 하나도 없었습니다.

```
ClickPipes / PeerDB    Postgres ──복제──▶ ClickHouse    (되어 있었음)
pg_clickhouse (FDW)    Postgres ◀──질의── ClickHouse    (없었음)
```

푸시다운은 두 번째가 있어야 합니다. 첫 번째를 아무리 잘해도 Postgres가 되읽을
방법은 생기지 않습니다. 이 둘을 뭉뚱그리는 것이 옮겨가지도 않은 쿼리를 옮겨갔다고
믿게 되는 가장 쉬운 길입니다 — 그리고 보낼 데가 아예 없었던 계획에 "Postgres에서
실행됨"이라고 쓰면 *없는* 푸시다운이 아니라 *실패한* 푸시다운으로 읽힙니다. 이
구분이 §10의 판정 엔진을 결정했습니다.

**래퍼가 받는 옵션은 추측하지 말고 래퍼에게 묻습니다.**

```sql
CREATE SERVER probe FOREIGN DATA WRAPPER clickhouse_fdw OPTIONS (bogus 'x');
-- ERROR:  invalid option "bogus"
-- HINT:   Valid options in this context are:
--         host, secure, min_tls_version, port, dbname, compression, driver, fetch_size
```

**foreign table은 임포트가 아니라 직접 선언했습니다.** ClickPipes는 `bike_trips`,
`bike_stations`로 넣지만 랩의 요점은 *같은 쿼리 텍스트*가 양쪽에서 도는 것입니다.
`table_name` 옵션이 이름을 바꿔 주므로 `{schema}.trips`에서 `bike` ↔ `ch`만
갈아끼우면 됩니다.

```sql
CREATE FOREIGN TABLE ch.trips (...) SERVER chsrv OPTIONS (table_name 'bike_trips');
```

PeerDB의 부기 컬럼은 일부러 뺐습니다. 모델의 일부가 아니고, 쿼리가 언급하지 않는
컬럼은 번역할 것이 하나 줄어듭니다.

### 9. 실제로 무엇이 내려가는가 — 측정

푸시다운은 두 단계이고 각 단계가 전부-아니면-전무입니다. 먼저 플래너는 조인에
참여하는 릴레이션이 **전부** 같은 foreign server에 있을 때만 foreign join을
만듭니다 — 로컬 테이블 하나면 조인은 여기 남습니다. 그다음에야 집계를 위에 얹을지
검토하고, 모든 집계 함수·`GROUP BY` 식·`HAVING` 조건을 래퍼가 번역할 수 있어야
합니다. 둘 중 하나가 어긋나면 부분적으로 되는 일은 없습니다. 집계 전체가 무너지고
원본 행이 네트워크를 건넙니다.

될 때는 플랜이 노드 하나입니다.

```
Foreign Scan
  Relations: Aggregate on ((trips t) INNER JOIN (stations s))
  Remote SQL: SELECT r2.district, count(*), round(avg(r1.duration_min), 1)
              FROM pg_sync.bike_trips r1
              ALL INNER JOIN pg_sync.bike_stations r2
                ON (r1.start_station_id = r2.station_id)
              GROUP BY r2.district ORDER BY count(*) DESC NULLS FIRST
```

KST 필터는 `extract(hour FROM started_at + interval '9 hours')` 같은 식을 만들고,
처음에는 이런 것들이 푸시다운을 깰 거라고 봤습니다 — 대표 쿼리를 푸시다운에 유리한
모양으로 다시 쓸까 고민할 만큼요. **틀렸습니다.** 쓰인 그대로 두고 28일 구간에서
집계 다섯 개 전부 옮겨갑니다.

| 쿼리 | 로컬 (`bike`) | 원격 (`ch`) |
|---|---|---|
| 자치구별 | 8,793 ms | 1,874 ms |
| 통행축 | 6,957 ms | 2,159 ms |
| 출퇴근/여가 | 3,219 ms | 1,530 ms |
| 시간대별 | 7,375 ms | 1,099 ms |
| 기간별 | 3,558 ms | 3,830 ms |

시간대 산술도 깔끔하게 번역됩니다.

```
extract(hour FROM started_at + interval '9 hours')      →  toHour(started_at + 32400)
date_trunc('quarter', started_at + interval '9 hours')  →  toStartOfQuarter(started_at + 32400)
```

버킷 다섯 종도 전부 내려가고, 읽는 쪽은 그대로인데 돌아오는 쪽만 줄어듭니다 —
롤업의 값싼 절반입니다.

| 버킷 | 로컬 | 원격 | 반환 행 |
|---|---|---|---|
| 1시간 | 2,631 ms | 1,742 ms | 15 |
| 24시간 | 3,927 ms | 1,610 ms | 15 |
| 1주 | 5,285 ms | 1,169 ms | 5 |
| 1개월 | 5,081 ms | 1,667 ms | 2 |
| 1분기 | 5,082 ms | 1,602 ms | 1 |

**Postgres 플랜이 원격이라고 말하는 것은 증거가 아닙니다.** ClickHouse에 직접
물었습니다.

```
11:44:30  1483 ms  read 24.11 million rows / 551 MiB  →  result_rows 15
          SELECT r2.district, r2.name, count(*), … cast(toHour((r1.started_at + 32400)) …
11:39:39  1563 ms  read 24.11 million rows / 735 MiB  →  result_rows 1
          SELECT toStartOfQuarter((r1.started_at + 32400)), count(*), …
```

결정적인 것은 **2,400만 행을 어디서 읽었는가**입니다. 저기서 읽었고 15행이
돌아왔습니다.

**자랑스럽지 않은 발견 하나.** ClickHouse는 28일 필터에도 24.11M 행을 전부
읽습니다. `started_at`이 정렬 키가 아니라 프루닝이 안 됩니다. 짧은 구간에서는 이것
때문에 로컬이 *더 빠릅니다* — 2일 구간에서 로컬 1,101 ms, 원격 2,078 ms. UI는
이걸 숨기지 않습니다.

### 10. 플랜을 정직하게 읽기

첫 판정 엔진은 플랜 텍스트에서 `Remote SQL`과 `GROUP BY`를 매칭했습니다. 이
방식은 서로 다른 세 결과를 구분하지 못합니다.

1. 집계가 보내졌다 (`pushed`)
2. 행이 끌려와 여기서 세어졌다 (`dragged`)
3. 계획에 foreign table이 아예 없었다 (`no_fdw`)

`EXPLAIN (FORMAT JSON)`을 트리로 순회하면 구분됩니다. `Foreign Scan` 노드를 찾아
`Remote SQL`과 행 수를 읽고, 그 위에 어떤 집계가 남았는지 확인합니다.

**`COSTS OFF`가 함정이었습니다.** 그걸 쓰면 "몇 행이 건넜나"가 매번 0으로
나왔는데, `COSTS OFF`가 비용과 함께 `Plan Rows`까지 지우기 때문입니다. 그 숫자가
이 화면의 전부인데 말이죠. 비용은 표시하지 않지만 `COSTS`는 켜 둡니다.

**추정과 실측을 다르게 표시합니다.** `ANALYZE` 없이는 플래너의 추측이고, 붙이면
실제 일어난 값이지만 쿼리를 두 번 실행하는 대가가 있습니다. 그래서 기본값이 아니라
체크박스입니다.

```
                            추정                       ANALYZE 실측
로컬   Limit→Sort→Aggregate→Sort→Hash Join            3,459,577행 통과   9,639 ms
원격   Foreign Scan                                   15행 회수          1,329 ms
```

플랜에서 가장 넓은 노드를 건넌 행과 별도로 추적합니다. "15행이 돌아왔다"는 말은
반대쪽이 그걸 필요 없게 만들려고 무엇을 했는지에 대해 아무것도 말해 주지 않기
때문입니다.

### 11. 대시보드가 강제한 것들

**14초짜리 쿼리를 15초마다 폴링하고 있었습니다.** 첫 overview 엔드포인트가
`count(DISTINCT started_at::date)`를 타이머로 돌렸는데, 이 행 수에서 그 쿼리는
14.3초입니다. 사실상 쉬지 않고 돌고 있었습니다. 2,400만 행에서 측정한 비용:

| 쿼리 | 시간 |
|---|---|
| `min/max(started_at)` | 15 ms (인덱스) |
| 최근 60분 분단위 | 18 ms (인덱스) |
| `count(*)` | 1.0 초 |
| 일별 롤업 전체 | 5.1 초 |
| `count(DISTINCT started_at::date)` | **14.3 초** |

엔드포인트를 둘로 나눈 것은 여기서 따라 나옵니다. 인덱스 작업만 하는 ~200 ms의
pulse는 폴링해도 되고, 스캔하는 것은 전부 **Run** 버튼 뒤에 둡니다. 이게 더 정직한
데모이기도 합니다 — 사실이 아직 Postgres에 있는 동안 어떤 질문이 비싼지 보입니다.

**기간은 프리셋이고 버킷은 기간에 종속됩니다.** 1일 구간에 1분기 버킷은 막대
하나이고, 1년 구간에 1시간 버킷은 덩어리입니다. 기간을 2~800개로 쪼개는 버킷만
제공하고, 기간은 오늘이 아니라 최신 대여에서 거슬러 셉니다. 데이터가 생성기가
마지막으로 쓴 지점에서 끝나기 때문입니다.

**클라이언트 바인딩은 의도된 선택입니다.** `ClientCursor`를 쓰면 화면의 SQL이 `$1`
박힌 템플릿이 아니라 실제 실행된 텍스트가 됩니다. 그리고 더 쓸모 있는 쪽 —
파라미터화된 쿼리는 foreign table에 플레이스홀더가 든 generic plan으로 도달하고,
상수를 못 보는 래퍼는 내려보낼 것이 줄어듭니다.

**팔레트는 고른 게 아니라 계산했습니다.** 파랑은 이미 Postgres, 노랑은 이미
ClickHouse를 뜻하고 있어서 데이터 계열은 다른 색이 필요했습니다. 검증된 카테고리
순서에서 그 둘만 빼고 나머지를 쓰니 검사에서 바로 떨어졌습니다 — magenta가 aqua
옆에 오면서 CVD ΔE 1.6, 적록색약 독자에게는 사실상 같은 색입니다. 인접 쌍 검증은
검증한 그 순서에서만 유효합니다. 3슬롯으로 줄여 all-pairs로 재검증하니 9.4로
통과했습니다.

**맹목적 절단은 짧은 라벨이 아니라 틀린 라벨을 만듭니다.** `slice(-5)`는 날짜를
잘 줄였고 이용시간 버킷 `90–105`를 `0–105`로 만들었습니다.

**문구가 같은 말을 두 번 하고 있었습니다.** 배지가 "ClickHouse"라고 하고 그
옆 문장이 ClickHouse가 셌다고 설명하는데, 그 옆 표에 이미 행 수가 있습니다.
화면은 사실을 말하고 설명은 About 탭에 둡니다.

### 12. 인용할 만한 수치

| | |
|---|---|
| 대여소 | 25개 자치구 2,789개 |
| 대여 | 228일간 24,037,356건 |
| 테이블 크기 | 7.1 GB (인덱스 포함 행당 256바이트) |
| WAL 생성량 | 행당 811바이트 |
| 실제 한 달 적재 | COPY로 164만 행 53초 |
| UTC 변환 | 23.87M 행 689초, 25만 행 배치 |
| 기본키 추가 | 164만 행 7.7초 |
| 실시간 피드 | 비피크 시간대 5분당 약 480건 |
| 푸시다운, 28일 구간 | 로컬 9,639 ms → 원격 1,329 ms |
| 플랜 노드 | 로컬 10개 → 원격 1개 |
| 옮긴 행 | 로컬은 정렬로 3,459,577행 통과, 원격은 15행 회수 |
| ClickHouse 쪽 확인 | `system.query_log`: 24.11M 읽고 15행 반환 |
| pulse 엔드포인트 | 204~235 ms. 15초 타이머의 14.3초 쿼리를 대체 |
| 짧은 구간 역전 | 2일 구간에서 로컬 1,101 ms, 원격 2,078 ms |

### 13. 남은 것

- **ClickHouse 정렬 키.** `started_at`이 정렬 키가 아니라 기간 필터가 아무것도
  잘라내지 못하고 창과 무관하게 24.11M 행을 다 읽습니다. 고치면 격차가 훨씬
  벌어지고 위의 짧은 구간 역전도 사라집니다.
- **`geom`은 `String`으로 복제됩니다.** ClickHouse에 지오메트리 타입이 없으니
  foreign table에서 `text`로 매핑하고 어떤 쿼리도 select하지 않습니다. 이 복제본은
  지오메트리를 옮기려는 게 아니라 *조인*이 원격에서 일어나게 하려고 있습니다.
- **행 추정이 부정확합니다.** `clickhouse_fdw`가 foreign scan을 1행으로 추정하는데
  실제는 15행입니다. 여기서 계획 선택이 바뀌지는 않았지만, 화면이 실측되지 않은
  수치를 추정이라고 표시하는 이유입니다.
