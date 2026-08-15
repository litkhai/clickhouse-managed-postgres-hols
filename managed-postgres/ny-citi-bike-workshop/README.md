# NY Citi Bike workshop — lives in its own repository

[English](#english) | [한국어](#한국어)

---

## English

**➜ [litkhai/lightweight-workshop-ny-citi-bike](https://github.com/litkhai/lightweight-workshop-ny-citi-bike)**
· **[documentation site](https://litkhai.github.io/lightweight-workshop-ny-citi-bike/)**

This directory is a pointer. The workshop itself is a separate repository, in
the same `lightweight-workshop-*` shape as
[LLMOps in a Box](https://github.com/litkhai/lightweight-workshop-llmops-in-a-box):
self-contained, English-only, published as its own documentation site, and
handed to external participants who clone it on its own.

### What it covers

The same split as [`postgis-fdw-bike/`](../postgis-fdw-bike/) — geometry in
Postgres, counting on ClickHouse — but on a feed that is **actually live** and
against **both** managed products end to end.

| | |
|---|---|
| Data | New York Citi Bike [GBFS](https://gbfs.org) — ~2,500 docks, public JSON, **no API key**, refreshed every 60s |
| Fact table | one row per station per snapshot, roughly 3.6M rows/day |
| Postgres | ClickHouse Managed Postgres — PostGIS points, the live collector, the publication |
| ClickHouse | ClickHouse Cloud — ClickPipes Postgres CDC, then `pg_clickhouse` foreign tables back in the Postgres session |
| Evidence | every query badged with a verdict read out of the execution plan |

Eight modules, about two hours. Two of them are **console walkthroughs**:
creating cloud services and connecting a ClickPipe are tied to a participant's
own account and billing, so the workshop clicks through them rather than asking
a public repository to hold an organization-wide API key.

### How it differs from `postgis-fdw-bike/`

| | [`postgis-fdw-bike/`](../postgis-fdw-bike/) | the workshop |
|---|---|---|
| Audience | this repository's readers | external participants, own accounts |
| Data | Seoul 따릉이 history — real **trip events** | Citi Bike GBFS — **live snapshots**, events derived by diffing |
| Volume | 1.6M trips/month, backfilled to ~24M | ~3.6M rows/day, accumulating live |
| Language | bilingual EN/KO | English only |
| Cloud half | Postgres side done, ClickHouse side in progress | written end to end, cloud modules unverified |

The two are complements. The Seoul lab has genuine trip events and the deeper
write-up; the workshop has a feed anyone can point at right now and a guided
path through both managed products.

### 📄 License

The workshop is [MIT](https://github.com/litkhai/lightweight-workshop-ny-citi-bike/blob/main/LICENSE)
in its own repository. Citi Bike data is published by Lyft Bikes and Scooters,
LLC under GBFS and is fetched at run time, not redistributed.

---

## 한국어

**➜ [litkhai/lightweight-workshop-ny-citi-bike](https://github.com/litkhai/lightweight-workshop-ny-citi-bike)**
· **[문서 사이트](https://litkhai.github.io/lightweight-workshop-ny-citi-bike/)**

이 디렉토리는 포인터입니다. 워크숍 본체는 별도 저장소에 있으며,
[LLMOps in a Box](https://github.com/litkhai/lightweight-workshop-llmops-in-a-box)와
같은 `lightweight-workshop-*` 형태입니다 — 독립 실행, 영문 전용, 자체 문서
사이트 발행, 외부 참가자가 단독으로 클론해 사용.

### 다루는 내용

[`postgis-fdw-bike/`](../postgis-fdw-bike/)와 같은 분업(지리는 Postgres,
집계는 ClickHouse)이지만, **실제로 살아 있는** 피드를 쓰고 **두 관리형 제품을
끝까지** 연결합니다.

| | |
|---|---|
| 데이터 | 뉴욕 Citi Bike [GBFS](https://gbfs.org) — 약 2,500개 거치대, 공개 JSON, **API 키 불필요**, 60초마다 갱신 |
| 팩트 테이블 | 스냅샷당 대여소 1행, 하루 약 360만 행 |
| Postgres | ClickHouse Managed Postgres — PostGIS 포인트, 실시간 수집기, 퍼블리케이션 |
| ClickHouse | ClickHouse Cloud — ClickPipes Postgres CDC, 이어서 `pg_clickhouse` 외래 테이블로 Postgres 세션에 복귀 |
| 근거 | 모든 쿼리에 실행 계획에서 읽어낸 판정 표시 |

8개 모듈, 약 2시간. 그중 둘은 **콘솔 화면 안내**입니다. 클라우드 서비스 생성과
ClickPipes 연결은 참가자 본인 계정·과금에 묶인 작업이라, 공개 저장소에 조직
전체 권한 API 키를 두는 대신 콘솔을 함께 클릭하는 방식으로 구성했습니다.

### `postgis-fdw-bike/`와의 차이

| | [`postgis-fdw-bike/`](../postgis-fdw-bike/) | 워크숍 |
|---|---|---|
| 대상 | 이 저장소 독자 | 외부 참가자, 각자 계정 |
| 데이터 | 서울 따릉이 이력 — 실제 **이동 이벤트** | Citi Bike GBFS — **실시간 스냅샷**, 이벤트는 차분으로 유도 |
| 규모 | 월 164만 건, 약 2,400만까지 백필 | 하루 약 360만 행, 실시간 누적 |
| 언어 | 영/한 병기 | 영문 전용 |
| ClickHouse 쪽 | Postgres 쪽 완료, ClickHouse 쪽 진행 중 | 끝까지 작성, 클라우드 모듈은 미검증 |

둘은 상호 보완입니다. 서울 랩은 진짜 이동 이벤트와 더 깊은 회고가 있고,
워크숍은 지금 당장 누구나 붙일 수 있는 피드와 두 관리형 제품을 관통하는 안내
경로가 있습니다.

### 📄 라이선스

워크숍은 자체 저장소에서
[MIT](https://github.com/litkhai/lightweight-workshop-ny-citi-bike/blob/main/LICENSE)입니다.
Citi Bike 데이터는 Lyft Bikes and Scooters, LLC가 GBFS로 발행하며 실행 시점에
받아옵니다 — 재배포하지 않습니다.
