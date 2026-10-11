# 실험 계획서: API 서버 없이 AWS Lambda → Managed Postgres · ClickHouse Cloud

> 작성 2026-10-11 · 이슈 [#29](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/29) · 실행 담당: 새 세션(이 문서만 읽고 시작) · 결과는 §11 양식으로 `RESULTS.md`에
>
> 이 문서는 특정 고객과 무관하다. 데이터는 스크립트가 만든 합성 데이터만 쓴다.
> 아직 아무것도 실행하지 않았다. §2의 사실은 모두 문서 근거이고, 측정값은 없다.

## 0. 새 세션 시작 순서

1. 이 저장소 `AGENTS.md`(core 영역 포함) → 이 문서 → 이슈 #29의 최근 댓글.
2. 공유 서비스 규칙(§8)을 먼저 읽는다. Seoul의 두 서비스는 라이브 데모가 쓰고 있다.
3. 자격 증명은 저장소 밖 로컬 파일에 있다. 위치는 이 프로젝트의 세션 메모리(소유자 로컬)에 적혀 있다. 값은 화면에 출력하지 않고 `source`만 한다.
4. **지출 전에 반드시 소유자에게 묻는다**: `terraform apply`, 서비스 크기 변경, IP 필터 변경, NAT 같은 유료 자원(§9).
5. 구현은 §12의 작업 단위로, 한 작업 = 한 커밋 크기. 실행 전 §2 "실행 전 다시 확인할 것"부터.

## 1. 목적과 질문

**주 목적**: 미들웨어나 상시 API 서버 없이 **Lambda 함수 하나가 Managed Postgres와 ClickHouse Cloud에 바로 붙어** 앱의 읽기·쓰기를 처리할 수 있는지, 그리고 그 구성이 **얼마나 싼지**를 측정한다.

답할 질문:

1. **Q1 SQL API**: Managed Postgres에 HTTP로 SQL을 실행하는 API가 있는가? (2026-10-11 문서 기준 없음. 실행일에 다시 확인하고, 없으면 "없음 — 확인 일자·문서"로 기록)
2. **Q2 Postgres 직결**: Lambda(VPC 밖)에서 `pg` 드라이버로 PgBouncer(6432)에 붙는 경로가 동작하는가? 차가운 시작·따뜻한 호출의 지연, 동시 호출 수에 따른 클라이언트·백엔드 연결 수.
3. **Q3 ClickHouse 직결**: Lambda에서 ClickHouse HTTPS(8443, `@clickhouse/client`)와 Query API Endpoint 두 경로의 지연. 서비스가 유휴(idle)일 때 첫 호출이 얼마나 걸리는가.
4. **Q4 연결 하나로 둘 다**: Lambda → Postgres 하나만 붙고 분석은 pg_clickhouse FDW로 ClickHouse에 넘기는 경로의 지연과 제약.
5. **Q5 (선택) HTTP만으로 Postgres 읽기**: Query API Endpoint의 저장 쿼리가 `postgresql()` 테이블 함수로 Managed Postgres를 읽는 우회 경로가 되는가, 얼마나 느린가.
6. **Q6 비용**: 고정비(월)와 요청 100만 건당 변동비. 어디에 돈이 드는지 측정값으로 나눈다(§7 비용 모형).
7. **Q7 네트워크 선택지**: VPC 밖 Lambda(나가는 IP 고정 안 됨)일 때 Postgres IP 필터를 어떻게 둘 수 있는가, 좁히려면 무엇이 얼마나 드는가(NAT EIP, PrivateLink).

비목적: 운영 수준의 보안·가용성 설계, API Gateway·프런트엔드, PrivateLink 실제 구성(Scale 등급 + 지원 티켓이 필요해 문서로만 다룸), 제품 간 우열 홍보.

## 2. 확인된 사실 (문서 근거, 읽은 날짜)

**Managed Postgres**
- SQL 실행용 HTTP API는 문서에 없다. OpenAPI는 서비스 생성·조회·설정용(control plane)이다. — [Managed Postgres OpenAPI](https://clickhouse.com/docs/products/managed-postgres/openapi) (2026-10-11)
- PgBouncer는 **transaction pooling** 모드, 포트 **6432**. 직접 연결은 5432. SQL 수준 `PREPARE`가 필요한 작업은 직접 연결. `max_prepared_statements` 기본 200(백엔드 연결당). 시작 파라미터 `application_name`·`TimeZone`은 되고 `extra_float_digits`·연결 문자열의 `search_path`는 `unsupported startup parameter`로 거부. 설정 확인은 6432의 `pgbouncer` DB에서 `SHOW CONFIG`. node-postgres(`pg`)는 PgBouncer에서 변경 없이 동작. — [Managed Postgres FAQ](https://clickhouse.com/docs/products/managed-postgres/faq) (2026-10-11)
- 서버리스 함수가 많아지면 연결 문자열을 PgBouncer(6432, 같은 호스트)로 바꾸라는 안내. TLS 예시는 `sslmode=verify-full` + CA 파일. — [Kysely 가이드](https://clickhouse.com/docs/products/managed-postgres/guides/kysely) (2026-10-11)
- **IP 필터를 하나도 두지 않으면 모든 IP에서 접속 허용**. Private Link는 self-service가 아니고 지원 티켓으로 구성. — [Managed Postgres Security](https://clickhouse.com/docs/products/managed-postgres/security) (2026-10-11)
- 요금: VM 구성(CPU·메모리·NVMe) 단위, 시간당. 서울 8 GiB 기준 단가(베타 50% 할인 반영, 표에 있는 그대로): r6gd Basic **$0.05190/h** · Scale $0.05882/h, m6gd Basic $0.08340/h. Basic은 인스턴스당 RAM 8 GiB 상한. **private networking은 Scale부터**. 일시 정지·scale to zero는 문서에 없음. 베타 중 백업·egress 과금 없음, GA 뒤 도입 예정. — [clickhouse.com/pricing](https://clickhouse.com/pricing), [Managed Postgres Pricing](https://clickhouse.com/docs/products/managed-postgres/pricing) (2026-10-11)
- AWS는 public beta, GCP는 private preview. — FAQ (2026-10-11)
- 이 저장소의 측정(2026-10-02, `provisioning/01-connect-test.sh`): PostgreSQL 18.6, TLS 1.3, `max_connections` 500.

**ClickHouse Cloud**
- **Query API Endpoints**: 저장한 쿼리를 `POST|GET https://console-api.clickhouse.cloud/.api/query-endpoints/<id>/run`으로 실행. Basic Auth(OpenAPI key id/secret), 최소 권한은 `Member` 조직 역할 + `Query Endpoints` 서비스 접근. 파라미터 `{name: Type}` → GET은 `param_<name>`, POST는 `queryVariables`. `format` 지정(v2는 모든 형식), v2만 스트리밍, `x-clickhouse-endpoint-version` 헤더. 실행 DB 역할(Full / Read only / custom)과 CORS 도메인을 엔드포인트마다 지정. **INSERT 가능**. `request_timeout` 기본 30000 ms. — [Query API Endpoints 가이드](https://clickhouse.com/docs/cloud/get-started/query-endpoints) (2026-10-11)
- Query API Endpoint는 ClickHouse 내부에서 프록시되므로 **서비스 IP 허용 목록이 적용되지 않고 API key의 IP 허용 목록**을 따른다. — [Query endpoints](https://clickhouse.com/docs/products/cloud/features/sql-console-features/query-endpoints) (2026-10-11)
- 요금: 유휴 시 compute가 0으로 내려가고 저장은 계속 과금. 서울 Enterprise compute $0.48010/unit-h(1 unit = 8 GiB·2 vCPU), 저장 $27.50/TB-월. Basic·Scale의 서울 단가는 페이지에 없음. 서울 인터넷 egress $0.144/GB. Query API Endpoint 별도 요금 언급 없음. — [clickhouse.com/pricing](https://clickhouse.com/pricing) (2026-10-11)
- 데이터 전송: **같은 리전 안 전송은 무료**, **공용 인터넷 egress는 출발 리전 기준 과금**, Private Link는 ClickHouse 쪽 과금 없음. VPC 밖 Lambda가 공용 엔드포인트로 받는 응답이 "같은 리전"인지 "공용 인터넷"인지는 문서가 직접 말하지 않는다 → **측정 항목**(§5 단계 6, 사용량 비용의 Data Transfer 줄). — [Network data transfer](https://clickhouse.com/docs/products/cloud/reference/billing/network-data-transfer) (2026-10-11)

**AWS (서울, AWS Price List API, Lambda 게시본 2026-10-09 · VPC 게시본 2026-09-17)**
- Lambda 요청 $0.20/100만. 실행 시간 arm64 $0.0000133334/GB-s(1단계), x86 $0.0000166667/GB-s. 무료 사용량 월 요청 100만·400,000 GB-s.
- 공용 IPv4 $0.005/h(사용 중 주소).
- NAT Gateway 서울 단가는 확인 못 함(EC2 가격표에 있음). 참고로 US East (Ohio)는 $0.045/h + $0.045/GB — [VPC pricing](https://aws.amazon.com/vpc/pricing/) (2026-10-11). 쓰기로 하면 실행 전 서울 값을 Price List로 뽑는다.
- Function URL 자체의 추가 요금은 Lambda 요금 페이지에 언급이 없다(2026-10-11) → 실행 전 확인.

**실행 전 다시 확인할 것**: 위 문서의 현재판(바뀌었으면 차이를 RESULTS.md에 기록), Lambda가 제공하는 Node.js 런타임 중 최신 LTS, `@clickhouse/client`·`pg` 최신판, 두 서비스의 현재 크기·버전·IP 필터 상태(읽기 전용), Seoul ClickHouse 서비스의 등급(Basic/Scale)과 idle 설정.

## 3. 구성

```
                 (호출: 로컬 측정 스크립트 → Lambda Invoke API, 일부는 Function URL)
                                   │
                          ┌────────▼────────┐  arm64, VPC 밖, 함수 1개(경로는 이벤트의 path 값)
                          │  Lambda 함수     │  연결·클라이언트는 핸들러 밖에서 만들고 warm 재사용
                          └─┬────┬────┬───┬─┘
         L-PGB (6432, TLS)  │    │    │   │  L-QE (HTTPS, Basic Auth)
              ┌─────────────┘    │    │   └───────────────────────────┐
              ▼                  │    │                               ▼
   PgBouncer ─▶ Postgres ◀───────┘    │                     Query API Endpoint
   (seoul-oltp) L-PG5432(대조)          │                     (console-api 프록시)
        │                             │ L-CH (HTTPS 8443)              │
        │ L-FDW: pg_clickhouse        ▼                                ▼
        └──────────────────────▶ ClickHouse Cloud "Seoul" ◀────────────┘
                                   │
               L-QEPG(선택): Query API Endpoint 안의 postgresql() ─▶ Postgres
```

| 경로 | 무엇 | 질문 |
|---|---|---|
| **L-PGB** | `pg` → PgBouncer 6432, `sslmode=verify-full` | Q2 |
| **L-PG5432** | 같은 코드, 5432 직접 연결(대조군) | Q2 |
| **L-CH** | `@clickhouse/client` → ClickHouse HTTPS 8443 | Q3 |
| **L-QE** | `fetch` → Query API Endpoint(저장 쿼리, 읽기 전용 역할) | Q3 |
| **L-FDW** | `pg` → PgBouncer → `SELECT` on pg_clickhouse 외래 테이블 | Q4 |
| **L-QEPG** (선택) | Query API Endpoint의 저장 쿼리가 `postgresql()`로 Postgres를 읽음 | Q5 |
| **NAT** (선택, 유료) | Lambda를 VPC 안 + NAT Gateway EIP에 두고 Postgres IP 필터를 그 /32로 좁힘 | Q7 |

결정과 이유:
- **언어 Node.js**: Managed Postgres 문서가 `pg`를 예로 들고, ClickHouse 공식 JS 클라이언트가 HTTP 기반이다. 런타임 버전은 실행일에 Lambda 문서로 확인.
- **arm64**: 서울 GB-s 단가가 x86보다 20% 낮다(§2).
- **함수 1개, 경로는 이벤트로 선택**: 배포물 하나로 경로 간 조건(메모리, 런타임, 코드)을 같게 한다. 메모리는 **256 MB 고정**, 기본 실행에서 경로별 튜닝 없음.
- **호출은 Invoke API가 기본**: 측정 스크립트가 `aws lambda invoke`(또는 boto3)로 부른다. Function URL은 **AuthType `AWS_IAM`** 으로 만들어 동작만 확인한다(공개 URL을 열어 두지 않음).
- **비밀값**: SSM Parameter Store SecureString(표준 등급)에 두고 init 단계에서 한 번 읽는다. Secrets Manager는 비밀당 월 요금이 있어 쓰지 않는다(요금은 실행 전 확인). Lambda 환경 변수에 평문으로 넣지 않는다.
- **연결 재사용**: `pg.Client` 하나를 핸들러 밖에서 만들고, 끊겼으면 다시 연결. 풀(`pg.Pool`)은 max 1. 동시성은 Lambda 실행 환경 수로 늘어난다.

## 4. 앱 시나리오와 데이터

가장 작은 "주문 + 이벤트" 앱. 시나리오마다 성공 1개, 실패 1개를 확인한다(core "demo is done" 규칙).

| 시나리오 | 경로 | 성공 확인 | 실패 확인 |
|---|---|---|---|
| S1 주문 쓰기 `POST /orders` | L-PGB | INSERT 후 같은 id로 SELECT 일치 | 잘못된 비밀번호 → 인증 오류를 그대로 반환(500 + 오류 코드) |
| S2 주문 읽기 `GET /orders/:id` | L-PGB, L-PG5432 | 행 반환 | 없는 id → 404 |
| S3 이벤트 쓰기 `POST /events` | L-CH(`async_insert=1`) | `SELECT count()` 증가 | 스키마에 없는 열 → ClickHouse 오류 원문 |
| S4 통계 `GET /stats?day=` | L-CH, L-QE, L-FDW | 세 경로 결과가 같음 | L-QE: IP 허용 목록 밖 key 또는 잘못된 key → 401 |
| S5 (선택) HTTP로 주문 읽기 | L-QEPG | S2와 같은 행 | Postgres 쪽 사용자 권한 없음 → 오류 원문 |
| S6 PgBouncer 제약 | L-PGB | 이름 붙은 prepared statement(드라이버 수준)는 동작 | SQL 수준 `PREPARE`/`EXECUTE`를 6432에서 → 문서대로 실패하는지 기록 |

데이터(스크립트가 생성, 고정 seed):
- Postgres DB `mpg_hols_lambda`: `orders(id bigserial, customer_id int, amount numeric(12,2), created_at timestamptz)` 10만 행.
- ClickHouse DB `mpg_hols_lambda`: `events(ts DateTime64(3), order_id UInt64, kind LowCardinality(String), value Float64)` MergeTree `ORDER BY (kind, ts)` 1,000만 행, 30일 분포.
- pg_clickhouse 외래 테이블은 **새 DB `mpg_hols_lambda` 안에서만** 만든다(seoul-oltp의 기존 pg_clickhouse 객체는 0.3, 건드리지 않음 — §8). 새 DB에서 `CREATE EXTENSION`할 버전은 실행일에 `pg_available_extension_versions`로 확인해 기록.

## 5. 절차

각 단계는 앞 단계 통과 뒤에만. 명령과 출력은 `logs/<날짜>/`에 남기고(gitignored), 요약만 RESULTS.md로.

### 단계 0 — 사전 확인 (읽기 전용, 지출 없음)
1. §2 "실행 전 다시 확인할 것"을 확인하고 바뀐 점 기록.
2. 두 서비스 현재 상태 저장: Managed Postgres 크기·버전·`haType`, IP 필터 목록(API 또는 콘솔), ClickHouse 서비스 등급·idle 설정·IP 허용 목록. **바꾸지 않는다.**
3. PgBouncer: `psql "...port=6432 dbname=pgbouncer" -c 'SHOW CONFIG'`에서 `pool_mode`, `default_pool_size`, `max_client_conn`, `max_db_connections` 기록.
4. seoul-oltp 스냅샷(§8): 스키마·확장·cron 작업·publication·foreign server 목록 저장.
5. **판정**: Postgres IP 필터가 비어 있지 않으면(특정 IP만 허용) VPC 밖 Lambda는 붙을 수 없다. 이때는 멈추고 소유자에게 선택지를 묻는다: (a) 실행 동안만 `0.0.0.0/0` 추가 후 즉시 제거, (b) NAT 경로만 실행, (c) 중단.

### 단계 1 — 배포 (소유자 승인 후)
- `terraform/`로 IAM 역할(최소 권한: CloudWatch Logs, 해당 SSM 파라미터 읽기), Lambda 함수(arm64, 256 MB, timeout 30 s), Function URL(`AWS_IAM`), 로그 그룹(보존 3일), SSM 파라미터. 모든 자원 태그 `purpose=mpg-lambda-direct`, `owner=<담당>`, `ttl=<날짜>`.
- DB 객체 생성 스크립트(`sql/`): Postgres DB·전용 사용자·테이블, ClickHouse DB·전용 사용자(읽기 전용 역할 하나 포함)·테이블, Query API Endpoint 2개(S4 통계, 선택 S5) — 엔드포인트는 콘솔 또는 API로, 만드는 방법과 id를 기록(id는 비밀이 아니지만 key는 비밀).
- 데이터 적재(§4).
- **판정**: `terraform plan` 결과를 소유자에게 보여 준 뒤 apply. 적재 행 수 확인.

### 단계 2 — 기능 (Q1–Q5)
- §4 표의 성공·실패 확인을 경로마다 1회. 응답 원문 저장.
- **판정**: 성공 확인이 모두 통과. 실패 확인은 "예상한 오류가 나왔는가"로 판정(예상과 다르면 그대로 기록, 고치지 않음).

### 단계 3 — 지연 (Q2–Q5)
- 측정은 **Lambda 안에서 잰 시간**이 주 지표: 핸들러 진입 → DB 응답까지(`performance.now()`), 연결 수립 시간 별도, 응답에 JSON으로 실어 보낸다. 클라이언트에서 잰 시간과 Lambda `REPORT` 줄(Init Duration, Duration, Billed Duration, Max Memory Used)도 함께 저장.
- **차가운 시작**: 환경 변수 하나를 바꿔 새 실행 환경을 강제한 뒤 1회, 경로마다 10회 반복.
- **따뜻한 호출**: 경로마다 순차 200회, p50·p95·p99.
- **ClickHouse 유휴 깨우기**: ClickHouse 서비스가 idle 상태임을 확인(콘솔 또는 API) → L-CH 1회, 다른 날·다른 시각에 L-QE 1회. 각 3번. idle 설정을 바꾸지 않는다. 공유 서비스라 idle이 아니면 "확인 못 함"으로 기록.

### 단계 4 — 동시성 (Q2)
- Lambda 예약 동시성을 100으로 두고, 동시 호출 1 → 10 → 50 → 100, 단계마다 60초.
- L-PGB와 L-PG5432 각각. 단계마다 기록: Postgres `SELECT count(*) FROM pg_stat_activity WHERE datname='mpg_hols_lambda'`(백엔드), PgBouncer `SHOW POOLS`(`cl_active`, `cl_waiting`, `sv_active`), 오류 수와 원문, 지연 p95.
- 상한 100은 공유 서비스 보호용(§8). 더 올리지 않는다.

### 단계 5 — (선택, 유료) NAT 경로 (Q7)
- 소유자가 고른 경우에만. VPC(퍼블릭 서브넷 1 + 프라이빗 서브넷 1), NAT Gateway 1, EIP 1. Lambda를 프라이빗 서브넷으로 옮기고 Postgres IP 필터에 EIP/32만 추가.
- 확인: EIP/32만 허용한 상태에서 L-PGB 성공, Lambda를 VPC 밖으로 돌리면 실패(접속 거부). 단계 3의 따뜻한 호출만 다시(NAT가 더하는 지연).
- 끝나면 즉시 NAT·EIP 삭제, IP 필터 원상복구.

### 단계 6 — 정리와 비용
- `terraform destroy`, 생성한 DB·사용자·Query API Endpoint 삭제, IP 필터·설정 원상복구, seoul-oltp 스냅샷과 diff(§8).
- 다음 날: AWS Cost Explorer 태그 `purpose=mpg-lambda-direct`, ClickHouse 사용량 비용(Usage Cost API)에서 실행 시간대의 compute·Data Transfer 줄. Data Transfer 줄이 §2의 미확인(같은 리전 공용 엔드포인트 과금 여부)을 답한다.

## 6. 측정 정의

| 지표 | 정의 |
|---|---|
| 서버 쪽 지연 | Lambda 안에서 핸들러 진입 → DB 응답 완료(ms). 연결 수립 시간은 따로 |
| 차가운 시작 | `REPORT`의 Init Duration + 첫 호출 Duration, 그리고 그중 DB 연결 수립 시간 |
| 따뜻한 지연 | 순차 200회의 p50·p95·p99 |
| 연결 수 | 동시성 단계별 Postgres 백엔드 수, PgBouncer 클라이언트·서버 연결 수 |
| GB-s/요청 | Billed Duration × 0.25 GB, 경로별 중앙값 |
| 유휴 깨우기 | idle 상태에서 첫 응답까지(클라이언트 시간) |

## 7. 비용 모형 ("이게 싼가"에 답하는 방법)

월 비용 = **고정** + **변동**.

- **고정**
  - Managed Postgres: 상시 켜져 있음(정지 기능 문서에 없음). 서울 r6gd 8 GiB Basic $0.05190/h × 730 h ≈ **$37.9/월**(베타 할인가, 2026-10-11 표). 할인이 끝나면 커질 수 있다.
  - ClickHouse Cloud: compute는 유휴 시 0, **저장은 상시**. 활동 시간 × 단가(서울 Basic/Scale 단가는 실행일 확인).
  - (선택) NAT: 시간당 요금 + EIP $0.005/h. 이 실험에서 가장 큰 "숨은 고정비" 후보.
- **변동** (요청 N건/월)
  - Lambda: N × $0.20/100만 + N × (GB-s/요청) × $0.0000133334 − 무료 사용량.
  - CloudWatch Logs 수집·보관(실행일 단가 확인).
  - ClickHouse egress(측정으로 과금 여부 확인), NAT 처리량(선택).
- 비교 기준선(문서 수치만, 측정 안 함): 같은 앱을 상시 EC2 API 서버 + 로드밸런서로 둘 때의 고정비. 단가는 실행일 Price List로.

보고할 값: 경로별 GB-s/요청(측정), 요청 100만·1,000만·1억 건/월의 월 비용 표(고정 + 변동), 손익분기 지점.
판단 규칙: 낮은·들쭉날쭉한 트래픽에서 Lambda 변동비가 무료 사용량 안팎이면 **월 비용은 Postgres 고정비가 거의 전부**가 된다 — 이것이 가설이고, 측정으로 확인하거나 반박한다.

## 8. 공유 서비스 안전 규칙 (Seoul)

- **Managed Postgres `seoul-oltp`** 에는 라이브 데모(bikemap, ny-citi-bike)와 분당 pg_cron 작업 3개, CDC 슬롯 2개가 있다(2026-10-02 기준).
  - 서비스를 삭제하거나 크기를 바꾸지 않는다. 기존 DB·확장·cron·publication·foreign server는 건드리지 않는다. 이 실험은 **새 DB `mpg_hols_lambda`와 전용 사용자** 안에서만.
  - 기존 pg_clickhouse 객체는 0.3이고 bikemap이 의존한다. `ALTER EXTENSION` 금지.
  - 실행 전후 스냅샷(스키마·확장·cron·publication·foreign server) diff.
  - 동시성 상한 100(단계 4). PgBouncer 설정 변경 금지.
- **ClickHouse Cloud `Seoul`**: 전용 DB `mpg_hols_lambda`와 전용 사용자만. `default`나 다른 DB 사용 금지. idle·크기 설정 변경 금지.
- **보안 설정 변경**(IP 필터, API key 허용 목록)은 소유자 승인 후, 실행 시간 동안만, 끝나면 원상복구하고 기록.
- 자동 승인 분류기가 막는 동작(비밀번호를 VM에서 가져오기, 공유 서비스의 테이블 삭제 등)은 우회하지 않고 소유자에게 실행할 명령 한 줄을 건넨다.

## 9. 예산

- 승인 받을 것: AWS 쪽 **$10 상한**(Lambda·로그·SSM; 예상은 무료 사용량 안), NAT 경로를 하면 그 시간만큼 추가. ClickHouse·Postgres는 기존 서비스라 늘어나는 것은 ClickHouse 활동 시간뿐.
- AWS Budgets 경보 $5·$8(태그 필터).
- 실행이 끊기면 정리(단계 6)부터.

## 10. 저장소에 들어갈 것

```
managed-postgres/lambda-direct/
  PLAN.md            이 문서
  README.md          영어 먼저, ## English / ## 한국어 (구현 때)
  RESULTS.md         §11 양식 (실행 뒤)
  config.env.example 호스트·사용자 자리표시자만 (호스트는 <service>.<id>.c0.<region>.aws.pg.clickhouse.cloud 형식)
  .gitignore         config.env, logs/, terraform/.terraform/, *.tfstate*, *.zip, dist/
  terraform/         main.tf variables.tf outputs.tf (+ nat.tf, count로 꺼 둠)
  function/          index.mjs package.json package-lock.json
  sql/               00-pg-setup.sql 01-ch-setup.sql 02-fdw.sql 99-cleanup.sql
  scripts/           00-preflight.sh 10-load.sh 20-functional.sh 30-latency.py 40-concurrency.py 90-snapshot.sh 99-teardown.sh
```

- `lab.yaml`은 게시 키 없이(또는 `web` 없이) 둔다. 게시는 소유자가 정한다.
- 루트 README 표에는 실행·검증이 끝난 뒤에만 넣는다("없는 lab에 링크 금지").
- Terraform state, `.zip`, `tfplan`은 절대 커밋하지 않는다(core Secrets).

## 11. 결과 보고 양식 (`RESULTS.md`)

```
# Results: Lambda → Managed Postgres / ClickHouse Cloud — <date>

## Environment
- Region/AZ, Lambda runtime + arch + memory, pg / @clickhouse/client versions
- Managed Postgres: size, PostgreSQL version, PgBouncer SHOW CONFIG values, IP filter state (before/after)
- ClickHouse Cloud: tier, version, idle setting
- Doc and price re-check: what changed since PLAN.md §2

## Q1 SQL API
- exists / does not exist — docs read on <date>

## Functional (S1–S6)
| scenario | path | positive | negative (expected error / got) |

## Latency (server-side ms)
| path | cold init | cold first call | of which connect | warm p50 | p95 | p99 |
| CH idle wake | L-CH: … | L-QE: … |

## Concurrency
| path | concurrency | PG backends | PgBouncer cl_active/cl_waiting/sv_active | errors | p95 |

## Network (Q7)
| option | worked | extra latency | monthly fixed cost |

## Cost
| item | measured / doc | value |
| month at 1M / 10M / 100M requests | fixed | variable | total |

## Conclusions (facts only)
## Actual cost (Cost Explorer by tag, ClickHouse usage cost for the run window)
```

## 12. 작업 분할 (구현 세션용)

한 작업 = 한 커밋 크기, 새 sub-agent 하나. 각 작업은 `allowed`(바꿔도 되는 파일)와 `verify`(통과해야 할 명령)를 가진다. 설계나 문서의 주장을 바꿔야 하면 구현자가 아니라 리드가 이 문서를 고친다.

| # | 작업 | allowed | verify |
|---|---|---|---|
| T1 | 뼈대: `.gitignore`, `config.env.example`, `lab.yaml`(runner·게시 키 없음) | 해당 3개 | `git check-ignore config.env logs/x terraform/terraform.tfstate`가 모두 무시됨, gitleaks 통과 |
| T2 | Lambda 코드: 경로 6개, 연결 재사용, 시간 측정 JSON | `function/` | 로컬: `node --check`, Postgres·ClickHouse 컨테이너(`extensions/pg-clickhouse-lab/docker-compose.yml` 재사용 가능)로 핸들러 직접 호출 테스트 |
| T3 | SQL·적재 스크립트 | `sql/`, `scripts/10-load.sh` | 로컬 컨테이너에서 생성·적재·삭제 1회 |
| T4 | Terraform | `terraform/` | `terraform fmt -check`, `terraform validate`, `terraform plan`(apply 금지) |
| T5 | 측정 스크립트(기능·지연·동시성·스냅샷·정리) | `scripts/` | `--dry-run`이 호출 목록만 출력, `shellcheck`, `python -m py_compile` |
| T6 | README(영·한) | `README.md` | 두 언어 절이 같은 내용, "Verified" 줄 없음(실행 전) |
| T7 | 실행(소유자 승인 후) → RESULTS.md, 정리, 다음 날 비용 | `RESULTS.md`, README 검증 줄 | 단계 6의 diff가 비어 있음, 자원 0개 |

## 13. 소유자가 정할 것

1. NAT 경로(단계 5)를 할지 — 하면 NAT 시간 요금이 붙는다.
2. L-QEPG(Q5, Query API Endpoint → `postgresql()`)를 할지.
3. 단계 0에서 Postgres IP 필터가 막혀 있으면 (a)/(b)/(c) 중 무엇.
4. 결과를 notes 사이트 lab 카드로 게시할지(`lab.yaml`의 `web`).
