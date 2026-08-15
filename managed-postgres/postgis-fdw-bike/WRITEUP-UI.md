# 만든 과정 2부 — ClickHouse 쪽과 대시보드

[WRITEUP.md](WRITEUP.md)는 Postgres 절반을 다룹니다. 거기서 랩은 "집계는
ClickHouse로 옮겨야 한다"고 주장한 채로 끝났습니다 — 주장만 하고, 옮겨지는 것을
보여주지는 않은 채로. 이 문서는 그 뒷부분입니다: FDW를 실제로 붙이고, 무엇이
내려가는지 재고, 어느 쪽이 답했는지 쿼리마다 보여주는 UI를 만든 기록입니다.

읽는 순서는 실제로 부딪힌 순서와 같습니다. 틀렸다가 고친 것도 그대로 남깁니다.

---

## 1. 복제가 된다고 푸시다운이 되는 게 아니다

시작할 때 상태는 이랬습니다.

```
pg_extension        plpgsql, pg_stat_ch, postgis, pg_clickhouse, pg_cron
pg_foreign_server   0
foreign_tables      0
ClickHouse pg_sync  bike_trips 24,063,550행 / bike_stations 2,789행
                    _peerdb_raw_mirror_… 도 존재
```

ClickPipes는 완벽하게 돌고 있었습니다. Postgres의 24,062,759행과 ClickHouse의
24,063,550행은 몇 초 차이일 뿐이고, 생성기가 넣는 행이 계속 따라가고 있었습니다.

그런데 `pg_foreign_server`가 0입니다. 이 둘은 **다른 방향**입니다:

```
ClickPipes / PeerDB    Postgres ──복제──▶ ClickHouse      (되어 있었음)
pg_clickhouse (FDW)    Postgres ◀──질의── ClickHouse      (없었음)
```

푸시다운은 두 번째가 있어야 성립합니다. 첫 번째가 아무리 잘 돌아도 Postgres가
ClickHouse를 읽을 방법은 생기지 않습니다. 이 구분을 UI가 흐리면 안 된다는 것이
뒤에 나올 판정 엔진 설계를 결정했습니다.

## 2. 래퍼가 받는 옵션은 래퍼에게 물어본다

`clickhouse_fdw`의 옵션을 문서에서 찾는 대신 validator에게 틀린 옵션을 줬습니다.

```sql
CREATE SERVER probe_srv FOREIGN DATA WRAPPER clickhouse_fdw OPTIONS (bogus_option 'x');
-- ERROR:  invalid option "bogus_option"
-- HINT:   Valid options in this context are:
--         host, secure, min_tls_version, port, dbname, compression, driver, fetch_size
```

이게 `sql/40-fdw-clickhouse.sql`이 쓰는 옵션 목록의 출처입니다. ClickHouse Cloud는
평문을 거부하므로 `secure 'true'`, 네이티브 프로토콜의 TLS 포트는 9440입니다.

**foreign table 이름을 직접 지었습니다.** ClickPipes는 `bike_trips` /
`bike_stations`로 넣지만, 랩의 요점은 *같은 쿼리 텍스트가 양쪽에 그대로 나가는
것*입니다. 그래서 `IMPORT FOREIGN SCHEMA` 대신 `table_name` 옵션으로 이름을
바꿔 선언했습니다.

```sql
CREATE FOREIGN TABLE ch.trips (...) SERVER chsrv OPTIONS (table_name 'bike_trips');
CREATE FOREIGN TABLE ch.stations (...) SERVER chsrv OPTIONS (table_name 'bike_stations');
```

이러면 `{schema}.trips`의 `{schema}`만 `bike` ↔ `ch`로 갈아끼우면 됩니다. PeerDB의
부기 컬럼(`_peerdb_synced_at`, `_peerdb_is_deleted`, `_peerdb_version`)은 일부러
뺐습니다 — 모델의 일부가 아니고, 쿼리가 언급하지 않는 컬럼은 푸시다운에서
신경 쓸 것이 하나 줄어듭니다.

## 3. 푸시다운은 통째로 되거나 아예 안 되거나

첫 EXPLAIN에서 바로 확인됐습니다.

```
Foreign Scan
  Relations: Aggregate on ((trips t) INNER JOIN (stations s))
  Remote SQL: SELECT r2.district, count(*), round(avg(r1.duration_min), 1)
              FROM pg_sync.bike_trips r1
              ALL INNER JOIN pg_sync.bike_stations r2
                ON (r1.start_station_id = r2.station_id)
              GROUP BY r2.district ORDER BY count(*) DESC NULLS FIRST
```

플랜 전체가 노드 하나입니다. 조인도, `GROUP BY`도, 집계도 전부 원격입니다.

규칙은 두 단계이고 각 단계가 전부-아니면-전무입니다.

1. **foreign join이 먼저 만들어져야 합니다.** 조인에 참여하는 릴레이션이 *전부*
   같은 foreign server에 있어야 합니다. 하나라도 로컬이면 조인은 여기 남습니다.
2. **그 위에 집계를 얹습니다.** 입력이 단일 foreign scan일 때만, 그리고 집계
   함수·`GROUP BY` 식·`HAVING` 조건을 전부 래퍼가 번역할 수 있을 때만.

둘 중 하나가 어긋나면 **부분적으로 내려가지 않습니다.** 집계 전체가 무너지고 원본
행이 네트워크를 건넙니다. `bike.stations`까지 굳이 복제하는 이유가 이것입니다 —
대여소 이름 하나 붙이려고 로컬 테이블을 섞으면 24M 행이 끌려옵니다.

## 4. 무엇이 번역되는가 — 추측하지 말고 재기

KST 필터가 `extract(hour FROM t.started_at + interval '9 hours')` 같은 식을
만들어 냅니다. 처음에는 이런 것들이 푸시다운을 깰 거라고 예상했고, 그래서 대표
쿼리를 푸시다운이 잘 되는 모양으로 다시 쓸까 고민했습니다. **틀린 걱정이었습니다.**
원문 쿼리를 그대로 두고 양쪽에 돌려 본 결과:

| 쿼리 | 로컬 (`bike`) | 원격 (`ch`) | 판정 |
|---|---|---|---|
| 자치구별 | 8,793 ms | 1,874 ms | pushed |
| 주요 통행축 | 6,957 ms | 2,159 ms | pushed |
| 출퇴근이냐 여가냐 | 3,219 ms | 1,530 ms | pushed |
| 시간대별 | 7,375 ms | 1,099 ms | pushed |
| 시간 흐름 | 3,558 ms | 3,830 ms | pushed |

다섯 개 전부 내려갑니다. 시간대 변환은 이렇게 번역됩니다:

```
extract(hour FROM started_at + interval '9 hours')  →  toHour(started_at + 32400)
date_trunc('quarter', started_at + interval '9 hours') → toStartOfQuarter(started_at + 32400)
```

버킷 롤업도 다섯 단위 전부 푸시다운됩니다.

| 버킷 | 로컬 | 원격 | 반환 행 |
|---|---|---|---|
| 1시간 | 2,631 ms | 1,742 ms | 15 |
| 24시간 | 3,927 ms | 1,610 ms | 15 |
| 1주 | 5,285 ms | 1,169 ms | 5 |
| 1개월 | 5,081 ms | 1,667 ms | 2 |
| 1분기 | 5,082 ms | 1,602 ms | 1 |

읽는 행은 매번 같고 돌아오는 행만 줄어듭니다. 이게 롤업의 값싼 절반입니다.

## 5. Postgres 플랜만 믿으면 순환논증이다

"플랜이 원격이라고 말하니까 원격이다"는 증명이 아닙니다. ClickHouse 자신에게
물었습니다.

```sql
SELECT event_time, query_duration_ms, read_rows, result_rows, query
FROM system.query_log WHERE type='QueryFinish' AND query ILIKE '%bike_trips%'
```

```
11:44:30  1483 ms  read 24.11 million rows / 551 MiB  →  result_rows 15
          SELECT r2.district, r2.name, count(*), … cast(toHour((r1.started_at + 32400)) …
11:39:39  1563 ms  read 24.11 million rows / 735 MiB  →  result_rows 1
          SELECT toStartOfQuarter((r1.started_at + 32400)), count(*), …
```

핵심은 **어디서 24M 행을 읽었는가**입니다. 저 스캔이 ClickHouse에서 일어났고 15행이
돌아왔습니다. `toHour`·`toStartOfQuarter`·`+ 32400`은 Postgres가 만들 수 없는
방언입니다. 중간중간 섞인 `INSERT INTO bike_trips`는 ClickPipes가 생성기 데이터를
계속 넣고 있는 것입니다.

**부수적으로 발견한 것:** 28일 필터인데도 ClickHouse가 24.11M 행을 전부 읽습니다.
`started_at`이 정렬 키가 아니라 파티션 프루닝이 안 됩니다. 푸시다운 실패는
아니지만 개선 여지이고, 짧은 구간에서는 이것 때문에 **로컬이 더 빠릅니다** —
2일 구간에서 로컬 1,101 ms / 원격 2,078 ms. UI는 이걸 숨기지 않습니다.

## 6. 판정 엔진 — 정규식에서 플랜 트리로

원래 UI는 플랜 텍스트에 `Remote SQL`이 있는지, 거기에 `GROUP BY`가 있는지를
정규식으로 봤습니다. 이 방식은 세 가지를 구분하지 못합니다.

1. 집계가 ClickHouse로 갔다 (`pushed`)
2. 행이 끌려와 여기서 세어졌다 (`dragged`)
3. **foreign table이 아예 없어서 보낼 데가 없었다** (`no_fdw`)

3번에 "Postgres에서 실행됨"이라고만 쓰면 푸시다운이 실패한 것처럼 읽힙니다. 실제로
세션 중에 이 오해가 그대로 일어났습니다. 그래서 `EXPLAIN (FORMAT JSON)`을 트리로
순회해 `Foreign Scan` 노드와 그 위에 남은 집계 노드를 직접 봅니다. 판정 코드는
`pushed` / `partial` / `dragged` / `local` / `no_fdw` / `geometry` / `series`
일곱 가지이고, 사람이 읽는 문구는 UI가 붙입니다.

**`COSTS OFF`의 함정.** 처음에 `EXPLAIN (VERBOSE, COSTS OFF, FORMAT JSON)`을 썼는데
"몇 행이 넘어왔나"가 계속 0으로 나왔습니다. `COSTS OFF`는 비용만이 아니라
`Plan Rows`까지 지웁니다. 그 숫자가 이 화면의 존재 이유인데 말이죠. 비용은 화면에
안 쓰지만 `COSTS`는 켜 둡니다.

**추정과 실측을 구분합니다.** `ANALYZE` 없이는 플래너 추정치이고, 붙이면 실제 행
수가 나옵니다. 대신 쿼리가 한 번 더 실행됩니다. 그래서 기본값이 아니라 체크박스로
두고, 화면에는 `추정`이라고 표시합니다.

```
                        추정              ANALYZE 실측
로컬  Limit→Sort→Aggregate→Sort→Hash Join   3,459,577행 통과   9,639 ms
원격  Foreign Scan                          15행 회수          1,329 ms
```

`rows_widest`(플랜에서 가장 넓은 노드)를 따로 재는 것은 이 대비 때문입니다.
"넘어온 행"만으로는 로컬 쪽 비용이 보이지 않습니다.

## 7. 14초짜리 쿼리를 15초마다 부르고 있었다

원래 overview 엔드포인트는 이걸 폴링했습니다.

```sql
SELECT count(DISTINCT started_at::date) FROM bike.trips;   -- 14.3초
```

15초 타이머로요. 사실상 쉬지 않고 돌고 있었습니다. 24M 행에서 실측한 비용:

| 쿼리 | 시간 |
|---|---|
| `min/max(started_at)` | 15 ms (인덱스) |
| 최근 60분 분단위 집계 | 18 ms (인덱스) |
| `count(*)` | 1.0 초 |
| 일별 롤업 전체 | 5.1 초 |
| `count(DISTINCT started_at::date)` | **14.3 초** |

그래서 엔드포인트를 둘로 나눴습니다.

- `/api/dashboard/pulse` — 인덱스 작업만. **204~235 ms**. 15초마다 폴링해도 됩니다.
  총 행 수는 `pg_class.reltuples` 추정치를 씁니다.
- `/api/dashboard/series` — 스캔하는 것 전부. **Run 버튼**을 눌러야 돌고, 필터를
  키로 120초 TTL 캐시를 둡니다.

**Run 버튼은 UI 취향이 아니라 이 측정의 결과입니다.** 탭을 눌러 구경하는 것이 남의
데모에 20초를 물리지 않아야 합니다. 그리고 사실이 아직 Postgres에 있는 동안 어떤
질문이 비싼지 보이는 편이 데모로서도 정직합니다.

기존의 `Semaphore(1)`은 그대로 뒀습니다 — 브라우저가 fetch를 취소해도 서버는 계속
실행하므로(`pg_stat_activity`로 확인) 쌓이는 것을 여기서 막아야 합니다.

## 8. 필터 — UTC 컬럼에 KST 얼굴 씌우기

컬럼은 UTC입니다. 사람이 "3일"이라고 할 때는 한국 날짜를 뜻합니다. KST의 하루 D는
UTC 구간 `[D 00:00 − 9h, D+1 00:00 − 9h)`이고, 이 변환은 `Filters` 클래스 한 곳에만
있습니다.

필터는 기간·자치구·시간대·평일/주말·그룹 최소 건수·버킷이고, 지도와 통계와
푸시다운 탭이 전부 같은 필터를 씁니다. 화면이 보여주는 슬라이스와 집계가 세는
슬라이스가 어긋나지 않게 하려는 것입니다.

**기간은 프리셋이고, 버킷은 기간에 종속됩니다.** 날짜를 직접 두 번 고르는 것보다
1일 / 1주 / 1개월 / 3개월 / 6개월 / 1년 / 사용자 지정이 빠릅니다. 기준은 오늘이
아니라 **데이터의 최신일**입니다 — 생성기가 마지막으로 쓴 지점에서 데이터가 끝나고,
"1주"가 빈 일주일을 뜻하면 기본값으로서 쓸모가 없습니다.

버킷은 유효한 것만 남깁니다. 기간을 2개 미만으로 쪼개는 버킷(1일 구간에 1분기)은
막대 하나짜리 차트이고, 800개를 넘기는 버킷은 덩어리입니다. 기간을 바꿔서 현재
버킷이 무효해지면 남은 것 중 가장 촘촘한 것으로 자동 보정합니다. 버킷을 통계 탭이
아니라 전역 필터 바에 둔 것도 이 때문입니다 — 대시보드 차트의 granularity까지 같이
따라가야 1년 범위에서 2픽셀짜리 막대 365개가 나오지 않습니다.

**"전체 선택" 버튼은 일부러 없앴습니다.** 자치구를 전부 고르는 것과 하나도 고르지
않는 것은 같은 행을 돌려주는데, 전자만 모든 쿼리에 25개짜리 `ANY(...)`를 붙입니다.
"해제"가 "전체"를 뜻하게 했습니다.

**`ClientCursor`를 쓴 이유가 두 가지입니다.** 화면에 보이는 SQL이 `$1`이 박힌
템플릿이 아니라 실제로 실행된 텍스트가 됩니다. 그리고 더 중요한 쪽 — 파라미터
바인딩된 쿼리는 foreign table에 플레이스홀더가 든 generic plan으로 도달하고,
상수를 못 보는 래퍼는 내려보낼 것이 줄어듭니다. 리터럴이 푸시다운에 유리합니다.

## 9. 차트 — 색은 계산해서 정한다

기존 UI에는 이미 **파랑 = Postgres / 노랑 = ClickHouse**라는 의미가 있었습니다.
그래서 그 둘은 상태 색으로 예약하고, 데이터 계열은 따로 골라야 했습니다.

처음에 참조 팔레트에서 파랑·노랑을 빼고 남은 순서를 그대로 썼습니다. 검증기를
돌리니 **실패**했습니다.

```
[FAIL] CVD separation  worst adjacent #d55181↔#199e70 ΔE 1.6 (deutan)
```

magenta와 aqua가 인접하게 되면서 적록색약에서 사실상 같은 색이 됩니다. 원래
팔레트의 인접 쌍 검증은 *그 순서에서만* 유효한데, 임의로 빼면 검증되지 않은 쌍이
새로 생깁니다. 눈으로 골랐으면 그대로 나갔을 것입니다.

차트당 계열이 최대 2개라 3슬롯으로 줄이고 all-pairs로 다시 검증해서 통과시켰습니다.

```
데이터 계열   #d95926 orange / #199e70 aqua / #9085e9 violet
              worst all-pairs CVD ΔE 9.4, normal 24.6  — PASS
상태 색       #6ea8fe Postgres / #faff69 ClickHouse
              분리 ΔE 35.1 (CVD) · 38.2 (normal), 큰 면적은 #cdd43b
```

밝기 밴드 검증에서 노랑이 계속 걸렸는데, 이건 계열색용 게이트라 상태 색에는
해당하지 않습니다(참조 팔레트의 status 색들도 밴드를 벗어납니다). 대신 큰 면적을
칠할 때는 톤을 낮춘 노랑을 씁니다.

마크는 고정 규격을 따릅니다: 막대 24px 이하에 데이터 끝만 4px 라운드, 선 2px,
마커 8px 이상에 배경색 2px 링, 면적 채움 10% 불투명도, 격자선은 1px 실선.
직접 라벨은 극값 하나에만 붙입니다.

**라벨 절단 버그.** 날짜를 짧게 보이려고 `String(v).slice(-5)`를 썼는데, 이용 시간
버킷 `90–105`가 `0–105`가 됐습니다. 짧은 라벨이 아니라 **틀린 라벨**입니다. 날짜
형태일 때만 자르도록 고쳤습니다.

## 10. 화면 구성

| 탭 | 하는 일 |
|---|---|
| 대시보드 | 맵과 차트를 한 그리드에. 상단 타일은 pulse로 계속 갱신 |
| 지도 | 공간 쿼리 4종 + 그 지도를 만든 SQL과 실행 계획 |
| 통계 | 집계 5종. **실행 대상 전환**(`bike` ↔ `ch`)과 버킷 선택 |
| 푸시다운 | 같은 쿼리를 양쪽에서 동시에. 배선 상태 → 판정 → 나란히 비교 |
| 로그 | 세션의 모든 쿼리. 행을 클릭하면 SQL·Remote SQL·실행 계획 |

지도와 통계는 **같은 사이드 패널 구조**를 공유합니다 — 제목, 설명, 판정 배지,
수치, SQL, 실행 계획. 두 화면이 같은 것을 같은 순서로 말하게 하려고 렌더러를
하나로 씁니다. 지도는 절대 푸시다운되지 않지만, "절대"라는 말은 실행 계획이
옆에 있을 때 더 잘 읽힙니다.

**실행 대상 전환은 환경변수가 아니라 화면에 있습니다.** 처음에는 `AGG_SCHEMA`
환경변수로만 바꿀 수 있게 했는데, 그러면 기본값이 로컬이라 통계 탭이 늘
"Postgres에서 실행됨"이라고 표시합니다. 요점의 절반을 보려고 재시작해야 하는 것은
나쁜 데모입니다. 지금은 foreign table이 있으면 기본값이 원격이고, 버튼으로 즉시
전환됩니다.

## 11. 군더더기를 걷어내기

첫 버전의 문구는 설명이 너무 많았습니다. `FDW 준비됨 · foreign table 2`,
`출퇴근이냐 여가냐`, `네트워크를 건넌 행`, 그리고 판정마다 두 줄짜리 해설.
화면에서 같은 말을 두 번 하고 있었습니다 — 배지가 "ClickHouse"라고 말한 다음
본문이 "ClickHouse가 셌습니다"라고 다시 말하는 식으로.

정리 원칙은 하나입니다: **화면은 사실을 말하고, 설명은 설명 탭에 둔다.**

```
FDW 준비됨 · foreign table 2   →  FDW 연결됨
출퇴근이냐 여가냐               →  출퇴근/여가
네트워크를 건넌 행              →  건넌 행
가장 넓은 플랜 노드             →  최대 노드
Remote SQL — ClickHouse로 실제 전송된 것  →  Remote SQL
```

푸시다운 배너도 마찬가지입니다.

```
이전: 조인과 집계가 둘 다 ClickHouse로 갔습니다. 원격 계획은 Foreign Scan
      하나입니다 — 완성된 결과만 건너왔습니다. 로컬 계획은 같은 15행을 얻으려고
      1.5M행을 조인과 정렬에 통과시켰고, 3.2배의 시간이 걸렸습니다. …

지금: 조인과 집계가 ClickHouse로 갔습니다.
      원격은 Foreign Scan 1개, 로컬은 노드 10개에 1.5M행 통과 · 3.2배.
```

숫자는 그대로 남기고 문장만 걷어냈습니다. 옆에 수치 표와 실행 계획이 이미 있으니
같은 내용을 산문으로 반복할 이유가 없습니다.

## 12. 한국어가 기본

서울 데이터이고 랩도 한국어로 진행하므로 한국어가 기본이고 영어가 두 번째
읽기입니다. 번역은 한곳에 모읍니다 — 서버는 **판정 코드**만 내려보내고 사람이 읽는
문구는 전부 클라이언트 사전에 있습니다. 필터 요약도 조각을 번역해 잇는 대신
언어별로 문장을 조립합니다(한국어는 수식어가 앞에 오고 조사가 붙습니다).

전환은 부분 재렌더 대신 새로고침입니다. 지도 하나·차트 넷·표 셋이 걸린 페이지에서
마운트된 문자열을 부분 교체하면 어딘가 하나는 옛 언어로 남습니다. `?lang=en`으로
링크할 수도 있고, 그 선택은 저장됩니다.

## 13. 인용할 만한 수치

| | |
|---|---|
| 푸시다운 (28일 구간) | 로컬 9,639 ms → 원격 1,329 ms |
| 플랜 노드 | 로컬 10개 → 원격 1개 |
| 로컬이 통과시킨 행 | 3,459,577 (조인 + 정렬) |
| 원격이 회수한 행 | 15 |
| ClickHouse 쪽 확인 | `system.query_log`: 24.11M 행 읽고 15행 반환 |
| 버킷 롤업 | 1시간·24시간·1주·1개월·1분기 전부 푸시다운 |
| pulse 엔드포인트 | 204~235 ms (교체 전 14.3초짜리를 15초마다 폴링) |
| 짧은 구간 역전 | 2일 구간에서 로컬 1,101 ms / 원격 2,078 ms |
| 팔레트 검증 | 첫 시도 CVD ΔE 1.6 로 실패 → 3슬롯 재검증 후 9.4 통과 |

## 14. 남은 것

- **ClickHouse 쪽 정렬 키.** `started_at`이 정렬 키가 아니라 기간 필터가 파티션을
  잘라내지 못합니다. 짧은 구간에서 로컬이 이기는 이유이고, 정렬 키를 바꾸면
  대비가 훨씬 커집니다.
- **`geom`은 `String`으로 복제됩니다.** ClickHouse에 지오메트리 타입이 없으니
  당연하지만, foreign table 선언에서 `text`로 매핑해 두고 어떤 쿼리도 select하지
  않습니다. 이 복제본이 존재하는 이유는 *조인*이 원격에서 일어나게 하기 위한
  것입니다.
- **추정 행 수가 부정확합니다.** `clickhouse_fdw`가 foreign scan의 행 수를 1로
  추정합니다. 실제로는 15행이고요. 계획 선택에는 영향이 없었지만, 화면이
  `추정`이라고 표시하는 이유이기도 합니다.
