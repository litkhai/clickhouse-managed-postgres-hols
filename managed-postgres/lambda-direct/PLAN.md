# 실험 계획서: API 서버 없이 AWS Lambda → Managed Postgres · ClickHouse Cloud

> 작성 2026-10-11 · 이슈 [#29](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/29) · 실행 담당: 새 세션(이 문서만 읽고 시작) · 결과는 §11 양식으로 `RESULTS.md`에
>
> **2026-10-11 개정** ([#35](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/35)): AWS 서버리스 비교 기준선(Aurora Serverless v2 + Data API, Aurora DSQL — Q8, 경로 L-AUR·L-DSQL) 추가, 비용 모형을 트래픽 모양 3가지로 나누고 경로별 청구 ms·로그 비용·EC2 기준선(문서 단가만) 추가, §2에 서울 단가(NAT·EC2·CloudWatch Logs·Aurora·Data API·DSQL) 채움.
>
> 이 문서는 특정 고객과 무관하다. 데이터는 스크립트가 만든 합성 데이터만 쓴다.
> 아직 아무것도 실행하지 않았다. §2의 사실은 모두 문서 근거이고, 측정값은 없다.

## 0. 새 세션 시작 순서

1. 이 저장소 `AGENTS.md`(core 영역 포함) → 이 문서 → 이슈 #29의 최근 댓글.
2. 공유 서비스 규칙(§8)을 먼저 읽는다. Seoul의 두 서비스는 라이브 데모가 쓰고 있다.
3. 자격 증명은 저장소 밖 로컬 파일에 있다. 위치는 이 프로젝트의 세션 메모리(소유자 로컬)에 적혀 있다. 값은 화면에 출력하지 않고 `source`만 한다.
4. **지출 전에 반드시 소유자에게 묻는다**: `terraform apply`, 서비스 크기 변경, IP 필터 변경, NAT·Aurora·DSQL 같은 유료 자원(§9, §13).
5. 구현은 §12의 작업 단위로, 한 작업 = 한 커밋 크기. 실행 전 §2 "실행 전 다시 확인할 것"부터.

## 1. 목적과 질문

**주 목적**: 미들웨어나 상시 API 서버 없이 **Lambda 함수 하나가 Managed Postgres와 ClickHouse Cloud에 바로 붙어** 앱의 읽기·쓰기를 처리할 수 있는지, 그리고 그 구성이 **얼마나 싼지**를 측정한다.

답할 질문:

1. **Q1 SQL API**: Managed Postgres에 HTTP로 SQL을 실행하는 API가 있는가? (2026-10-11 문서 기준 없음. 실행일에 다시 확인하고, 없으면 "없음 — 확인 일자·문서"로 기록)
2. **Q2 Postgres 직결**: Lambda(VPC 밖)에서 `pg` 드라이버로 PgBouncer(6432)에 붙는 경로가 동작하는가? 차가운 시작·따뜻한 호출의 지연, 동시 호출 수에 따른 클라이언트·백엔드 연결 수.
3. **Q3 ClickHouse 직결**: Lambda에서 ClickHouse HTTPS(8443, `@clickhouse/client`)와 Query API Endpoint 두 경로의 지연. 서비스가 유휴(idle)일 때 첫 호출이 얼마나 걸리는가.
4. **Q4 연결 하나로 둘 다**: Lambda → Postgres 하나만 붙고 분석은 pg_clickhouse FDW로 ClickHouse에 넘기는 경로의 지연과 제약.
5. **Q5 (선택) HTTP만으로 Postgres 읽기**: Query API Endpoint의 저장 쿼리가 `postgresql()` 테이블 함수로 Managed Postgres를 읽는 우회 경로가 되는가, 얼마나 느린가.
6. **Q6 비용**: 고정비(월)와 요청 100만 건당 변동비, **경로별 청구 ms**와 **로그 비용**까지. 어디에 돈이 드는지 측정값으로 나누고, 트래픽 모양 3가지(드문드문·꾸준함·많음)마다 월 비용과 손익분기를 낸다(§7 비용 모형).
7. **Q7 네트워크 선택지**: VPC 밖 Lambda(나가는 IP 고정 안 됨)일 때 Postgres IP 필터를 어떻게 둘 수 있는가, 좁히려면 무엇이 얼마나 드는가(NAT EIP, PrivateLink).
8. **Q8 AWS 서버리스 기준선**: 같은 Lambda 코드·같은 시나리오(S1·S2)를 (a) **Aurora Serverless v2 + 자동 일시정지 + RDS Data API**(HTTP SQL, IAM, VPC·NAT 없음), (b) **Aurora DSQL**로 돌리면 지연·깨어나는 시간·요청당 비용이 어떤가. ClickHouse 구성이 어떤 트래픽 모양에서 싸고 어디서 비싼지를 숫자로 보이기 위한 비교이고, 우열 결론을 내지 않는다.

비목적: 운영 수준의 보안·가용성 설계, API Gateway·프런트엔드, PrivateLink 실제 구성(Scale 등급 + 지원 티켓이 필요해 문서로만 다룸), DynamoDB·Athena(데이터 모델이 달라 같은 코드로 비교할 수 없음 — §7에 문서 단가로만), 제품 간 우열 홍보.

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

**AWS 단가 (서울 ap-northeast-2, AWS Price List API — Lambda·EC2·RDS·AuroraDSQL·DynamoDB·Athena·CloudWatch 게시본 2026-10-09, VPC 게시본 2026-09-17, 읽은 날 2026-10-11)**

| 항목 | 단가 |
|---|---|
| Lambda 요청 | $0.20/100만 |
| Lambda 실행 시간 | arm64 $0.0000133334/GB-s(1단계), x86 $0.0000166667/GB-s. 무료 월 요청 100만·400,000 GB-s |
| CloudWatch Logs | 수집 $0.76/GB(Standard), 보관 $0.0314/GB-월 |
| 공용 IPv4 | $0.005/h(사용 중 주소) |
| NAT Gateway | **$0.059/h + $0.059/GB 처리** |
| EC2 (기준선, 측정 안 함) | t4g.nano $0.0052/h · t4g.micro $0.0104/h · t4g.small $0.0208/h(Linux, 온디맨드), gp3 $0.0912/GB-월 |
| Aurora PostgreSQL Serverless v2 | $0.20/ACU-h(Standard), $0.26/ACU-h(I/O-Optimized), 저장 $0.12/GB-월, I/O $0.24/100만 |
| RDS Data API | 요청당 $0.00000042(10억 건까지, = $0.42/100만), 그 이후 $0.00000024 |
| Aurora DSQL | DPU당 $0.00001(= $10/100만 DPU), 저장 $0.40/GB-월. 무료 월 10만 DPU·1 GB |
| DynamoDB 온디맨드 (문서만) | 쓰기 $0.68/100만 WRU, 읽기 $0.1355/100만 RRU, 저장 25 GB 무료 뒤 $0.27075/GB-월 |
| Athena (문서만) | 스캔 $5/TB |

- Function URL 자체의 추가 요금은 Lambda 요금 페이지에 언급이 없다(2026-10-11) → 실행 전 확인. Secrets Manager 비밀 월 요금(L-AUR에 필요)도 실행 전 Price List로.

**Aurora Serverless v2 자동 일시정지 · RDS Data API** — [auto-pause](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html), [Data API](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/data-api.html) (2026-10-11)
- 최소 용량 **0 ACU**로 두면 사용자 연결이 없을 때 일시정지하고, 그동안 **인스턴스 요금은 0**(저장 등은 계속 과금). Aurora PostgreSQL은 16.3·15.7·14.12·13.15 이상.
- 일시정지까지 대기 `SecondsUntilAutoPause`: 최소 300초(기본), 최대 86,400초.
- 깨어나는 데 **보통 약 15초**, 24시간 넘게 쉬면 더 깊은 잠으로 **30초 이상**. 연결 시간 제한을 그보다 길게 두라고 권한다. Data API 요청도 writer를 깨운다.
- 일시정지가 안 되는 경우: 사용자 연결이 열려 있음, 논리 복제 켬, **RDS Proxy 연결**, 글로벌 DB, zero-ETL 통합. 깨어난 직후는 낮은 용량에서 시작해 늘어난다.
- Data API: HTTP 엔드포인트로 SQL 실행, 지속 연결 불필요. DB 자격 증명은 **Secrets Manager**, 호출은 IAM 권한. "VPC 안에 Lambda를 둘 필요 없이" 접근 가능. 지원 버전·리전·제한(응답 크기 등)은 실행 전 [지역·버전](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/data-api.regions.html)·[제한](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/data-api.limitations.html) 페이지로 확인.

**Aurora DSQL** — [PostgreSQL 호환성](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-unsupported-features.html), [요금](https://aws.amazon.com/rds/aurora/dsql/pricing/), [서울 출시(2025-07)](https://aws.amazon.com/about-aws/whats-new/2025/07/amazon-aurora-dsql-additional-regions/) (2026-10-11)
- 서울에서 사용 가능. PostgreSQL wire protocol이라 `pg` 드라이버로 붙는다. 유휴 시 DPU 과금 없음.
- 제약: 클러스터당 DB 하나(`postgres`), 정렬 `C`만, 격리 수준 `Repeatable Read` 고정, **트랜잭션당 수정 3,000행**, DDL과 DML은 다른 트랜잭션·트랜잭션당 DDL 1개, 연결 1시간 제한, 임시 테이블·PL/pgSQL·트리거 없음, `TRUNCATE` 대신 `DELETE`, `CREATE INDEX ASYNC`. 낙관적 동시성 제어라 충돌 시 직렬화 오류 → 재시도 필요.
- 인증 방식(IAM 토큰)과 토큰 생성 라이브러리 이름, DPU 사용량을 보는 CloudWatch 지표 이름은 이번에 읽은 문서에 없었다 → 실행 전 확인.

**실행 전 다시 확인할 것**: 위 문서의 현재판(바뀌었으면 차이를 RESULTS.md에 기록), Lambda가 제공하는 Node.js 런타임 중 최신 LTS, `@clickhouse/client`·`pg`·`@aws-sdk/client-rds-data` 최신판, 두 서비스의 현재 크기·버전·IP 필터 상태(읽기 전용), Seoul ClickHouse 서비스의 등급(Basic/Scale)과 idle 설정, 서울의 Aurora PostgreSQL 최신 버전과 0 ACU 지원 여부(`describe-orderable-db-instance-options`), DSQL 인증·지표.

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

   AWS 서버리스 기준선 (Q8, 같은 함수, 이 실험 전용 새 자원):
     Lambda ── L-AUR: RDS Data API (HTTPS, IAM) ──▶ Aurora PostgreSQL Serverless v2 (0 ACU 자동 일시정지)
     Lambda ── L-DSQL: pg (TLS, IAM 토큰) ────────▶ Aurora DSQL (단일 리전 클러스터)
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
| **L-AUR** (기준선) | `@aws-sdk/client-rds-data` `ExecuteStatement` → Aurora Serverless v2(min 0 / max 2 ACU, `SecondsUntilAutoPause=300`, writer 1개, 단일 AZ) | Q8 |
| **L-DSQL** (기준선) | `pg` → DSQL 엔드포인트, 비밀번호 자리에 IAM 인증 토큰 | Q8 |

결정과 이유:
- **언어 Node.js**: Managed Postgres 문서가 `pg`를 예로 들고, ClickHouse 공식 JS 클라이언트가 HTTP 기반이다. 런타임 버전은 실행일에 Lambda 문서로 확인.
- **arm64**: 서울 GB-s 단가가 x86보다 20% 낮다(§2).
- **함수 1개, 경로는 이벤트로 선택**: 배포물 하나로 경로 간 조건(메모리, 런타임, 코드)을 같게 한다. 메모리는 **256 MB 고정**, 기본 실행에서 경로별 튜닝 없음.
- **호출은 Invoke API가 기본**: 측정 스크립트가 `aws lambda invoke`(또는 boto3)로 부른다. Function URL은 **AuthType `AWS_IAM`** 으로 만들어 동작만 확인한다(공개 URL을 열어 두지 않음).
- **비밀값**: SSM Parameter Store SecureString(표준 등급)에 두고 init 단계에서 한 번 읽는다. Lambda 환경 변수에 평문으로 넣지 않는다. 예외는 L-AUR: Data API가 **Secrets Manager** 비밀을 요구하므로 Aurora 관리형 마스터 비밀번호(`--manage-master-user-password`)를 쓰고, 그 월 요금을 L-AUR 비용에 넣는다. L-DSQL은 비밀이 없다(IAM 토큰).
- **연결 재사용**: `pg.Client` 하나를 핸들러 밖에서 만들고, 끊겼으면 다시 연결. 풀(`pg.Pool`)은 max 1. 동시성은 Lambda 실행 환경 수로 늘어난다. DSQL은 연결 1시간 제한이 있어, 토큰 만료·연결 끊김 시 다시 연결하는 코드를 같은 자리에 둔다. L-AUR은 연결이 없다(HTTP 호출마다 독립).
- **기준선의 공정성**: L-AUR·L-DSQL도 같은 함수·같은 메모리·같은 시나리오·같은 데이터 크기. 엔진별 튜닝은 기본 실행에서 하지 않는다. 불리한 결과도 그대로 기록한다. 재시도는 문서가 요구하는 것만(DSQL 직렬화 오류, Aurora 깨어나는 동안의 연결 실패), 횟수를 기록한다.
- **Aurora 버전·크기**: 서울에서 0 ACU를 지원하는 최신 Aurora PostgreSQL(§2 하한 이상, 실행일 확인). 최대 2 ACU는 작은 앱 기준이고 비용 상한용이다. RDS Proxy·논리 복제·zero-ETL은 켜지 않는다(일시정지를 막음).

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
| S1·S2 (기준선) | L-AUR, L-DSQL | 위 S1·S2와 같은 확인 | L-AUR: 비밀 읽기 권한이 없는 IAM 역할 → `AccessDenied` 원문 · L-DSQL: 한 트랜잭션에서 3,001행 수정 → 제한 오류 원문 |
| S7 깨어나기 (기준선) | L-AUR | 일시정지 상태에서 첫 요청이 성공(걸린 시간 기록) | Lambda·SDK 시간 제한을 10초로 낮춘 1회 → 시간 초과가 나는지 기록(문서의 약 15초와 비교) |

데이터(스크립트가 생성, 고정 seed):
- Postgres DB `mpg_hols_lambda`: `orders(id bigserial, customer_id int, amount numeric(12,2), created_at timestamptz)` 10만 행. Aurora에도 같은 표·같은 행. DSQL은 `id uuid`(앱에서 생성, DSQL 문서 권장)로 바꾼 같은 표를 `postgres` DB의 전용 스키마 `mpg_hols_lambda`에 두고, 적재는 트랜잭션당 1,000행으로 나눈다(3,000행 제한). 이 차이를 결과에 적는다.
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
- `terraform/`로 IAM 역할(최소 권한: CloudWatch Logs, 해당 SSM 파라미터 읽기), Lambda 함수(arm64, 256 MB, timeout 60 s — Aurora가 깨어나는 30초 이상을 견디도록), Function URL(`AWS_IAM`), 로그 그룹(보존 3일), SSM 파라미터. 모든 자원 태그 `purpose=mpg-lambda-direct`, `owner=<담당>`, `ttl=<날짜>`.
- 기준선(Q8, 소유자가 고른 경우 — §13): `aurora.tf`(Aurora 클러스터 + `db.serverless` writer 1개, min 0 / max 2 ACU, Data API 켬, 관리형 마스터 비밀번호, 기본 VPC의 DB 서브넷 그룹, 퍼블릭 접근 없음, 삭제 보호 끔, 최종 스냅샷 생략), `dsql.tf`(단일 리전 클러스터, 삭제 보호 끔). Lambda 역할에 `rds-data:ExecuteStatement`·해당 비밀 읽기, DSQL 연결 권한(액션 이름은 실행일 확인)을 더한다. 둘 다 `count` 변수로 끄고 켠다.
- DB 객체 생성 스크립트(`sql/`): Postgres DB·전용 사용자·테이블, ClickHouse DB·전용 사용자(읽기 전용 역할 하나 포함)·테이블, Query API Endpoint 2개(S4 통계, 선택 S5) — 엔드포인트는 콘솔 또는 API로, 만드는 방법과 id를 기록(id는 비밀이 아니지만 key는 비밀).
- 데이터 적재(§4).
- **판정**: `terraform plan` 결과를 소유자에게 보여 준 뒤 apply. 적재 행 수 확인.

### 단계 2 — 기능 (Q1–Q5, Q8)
- §4 표의 성공·실패 확인을 경로마다 1회. 응답 원문 저장.
- **판정**: 성공 확인이 모두 통과. 실패 확인은 "예상한 오류가 나왔는가"로 판정(예상과 다르면 그대로 기록, 고치지 않음).

### 단계 3 — 지연 (Q2–Q5, Q8)
- 측정은 **Lambda 안에서 잰 시간**이 주 지표: 핸들러 진입 → DB 응답까지(`performance.now()`), 연결 수립 시간 별도, 응답에 JSON으로 실어 보낸다. 클라이언트에서 잰 시간과 Lambda `REPORT` 줄(Init Duration, Duration, Billed Duration, Max Memory Used)도 함께 저장.
- **차가운 시작**: 환경 변수 하나를 바꿔 새 실행 환경을 강제한 뒤 1회, 경로마다 10회 반복.
- **따뜻한 호출**: 경로마다 순차 200회, p50·p95·p99.
- **ClickHouse 유휴 깨우기**: ClickHouse 서비스가 idle 상태임을 확인(콘솔 또는 API) → L-CH 1회, 다른 날·다른 시각에 L-QE 1회. 각 3번. idle 설정을 바꾸지 않는다. 공유 서비스라 idle이 아니면 "확인 못 함"으로 기록.
- **Aurora 깨어나기 (S7)**: 요청을 멈추고 `ServerlessDatabaseCapacity`가 0이 된 것을 CloudWatch로 확인(300초 + 여유) → L-AUR 1회, 클라이언트 시간·서버 쪽 시간·RDS 이벤트(`RDS-EVENT-0370`~`0374`) 기록. 3번. 24시간 넘는 깊은 잠은 실행이 하루를 넘길 때만(§13).
- **청구 ms**: 모든 경로의 `REPORT` 줄에서 Billed Duration을 모은다. 이것이 §7 변동비의 입력이다.

### 단계 4 — 동시성 (Q2, Q8)
- Lambda 예약 동시성을 100으로 두고, 동시 호출 1 → 10 → 50 → 100, 단계마다 60초.
- L-PGB와 L-PG5432 각각. 단계마다 기록: Postgres `SELECT count(*) FROM pg_stat_activity WHERE datname='mpg_hols_lambda'`(백엔드), PgBouncer `SHOW POOLS`(`cl_active`, `cl_waiting`, `sv_active`), 오류 수와 원문, 지연 p95.
- 기준선도 같은 단계로: L-AUR(오류·스로틀·ACU 변화), L-DSQL(오류·직렬화 재시도 수·연결 수).
- 상한 100은 공유 서비스 보호용(§8). 더 올리지 않는다.

### 단계 4-b — 요청당 사용량 (Q6, Q8)
- 정해진 요청 수(경로마다 10,000건, 동시성 10)를 보내고 그 구간의 사용량을 읽는다: Lambda 청구 GB-s 합계, 로그 바이트(로그 그룹 `storedBytes` 전후 차 또는 수집량 지표), L-AUR의 ACU-시간(`ServerlessDatabaseCapacity` 평균 × 시간)과 Data API 요청 수, L-DSQL의 DPU(지표 이름은 실행일 확인), Managed Postgres는 고정비라 사용량 없음, ClickHouse는 Usage Cost API.
- 결과: 경로별 **요청 1건당** GB-s·로그 바이트·ACU-s·DPU.
- 로그 줄이기 1회: Lambda 로그 수준 설정으로 애플리케이션·플랫폼 로그를 줄일 수 있는지 실행일 문서로 확인하고, 되면 같은 10,000건을 다시 보내 로그 바이트를 비교한다.

### 단계 5 — (선택, 유료) NAT 경로 (Q7)
- 소유자가 고른 경우에만. VPC(퍼블릭 서브넷 1 + 프라이빗 서브넷 1), NAT Gateway 1, EIP 1. Lambda를 프라이빗 서브넷으로 옮기고 Postgres IP 필터에 EIP/32만 추가.
- 확인: EIP/32만 허용한 상태에서 L-PGB 성공, Lambda를 VPC 밖으로 돌리면 실패(접속 거부). 단계 3의 따뜻한 호출만 다시(NAT가 더하는 지연).
- 끝나면 즉시 NAT·EIP 삭제, IP 필터 원상복구.

### 단계 6 — 정리와 비용
- `terraform destroy`(Aurora 클러스터·Secrets Manager 비밀·DSQL 클러스터 포함 — 비밀은 복구 대기 없이 삭제), 생성한 DB·사용자·Query API Endpoint 삭제, IP 필터·설정 원상복구, seoul-oltp 스냅샷과 diff(§8). 태그 `purpose=mpg-lambda-direct`로 남은 자원이 없는지 `resourcegroupstaggingapi`로 확인.
- AWS 비용: Cost Explorer는 쓰지 않는다(소유자 계정에 접근 권한 없음, 2026-10-11). Price List 단가 × 측정한 사용량(요청 수, Billed Duration 합계 GB-s, 로그 수집량, NAT 시간, Aurora ACU-시간·저장·I/O·Data API 요청, DSQL DPU·저장, 비밀 보관 일수)으로 **추정**하고 추정이라고 표시한다.
- 다음 날: ClickHouse 사용량 비용(Usage Cost API)에서 실행 시간대의 compute·Data Transfer 줄. Data Transfer 줄이 §2의 미확인(같은 리전 공용 엔드포인트 과금 여부)을 답한다.

## 6. 측정 정의

| 지표 | 정의 |
|---|---|
| 서버 쪽 지연 | Lambda 안에서 핸들러 진입 → DB 응답 완료(ms). 연결 수립 시간은 따로 |
| 차가운 시작 | `REPORT`의 Init Duration + 첫 호출 Duration, 그리고 그중 DB 연결 수립 시간 |
| 따뜻한 지연 | 순차 200회의 p50·p95·p99 |
| 연결 수 | 동시성 단계별 Postgres 백엔드 수, PgBouncer 클라이언트·서버 연결 수 |
| 청구 ms | `REPORT`의 Billed Duration, 경로별 중앙값·p95 |
| GB-s/요청 | Billed Duration × 0.25 GB, 경로별 중앙값(단계 4-b는 합계 ÷ 요청 수) |
| 로그 바이트/요청 | 단계 4-b 구간의 로그 수집량 ÷ 요청 수 |
| ACU-s/요청 (L-AUR) | 단계 4-b 구간의 `ServerlessDatabaseCapacity` 평균 × 구간 초 ÷ 요청 수 |
| DPU/요청 (L-DSQL) | 단계 4-b 구간의 DPU 합 ÷ 요청 수 |
| 유휴 깨우기 | idle(ClickHouse) 또는 일시정지(Aurora) 상태에서 첫 응답까지(클라이언트 시간) |

## 7. 비용 모형 ("이게 싼가"에 답하는 방법)

월 비용 = **고정** + **변동**. 단가는 §2, 요청당 사용량은 단계 4-b 측정값을 넣는다.

### 7.1 항목

- **공통 (모든 구성)**
  - Lambda: N × $0.20/100만 + N × (GB-s/요청) × $0.0000133334 − 무료(요청 100만·400,000 GB-s).
  - CloudWatch Logs: N × (로그 바이트/요청) × $0.76/GB + 보관 $0.0314/GB-월.
- **A. Managed Postgres + ClickHouse (본 실험)**
  - 고정: Managed Postgres 상시(정지 기능 문서에 없음). r6gd 8 GiB Basic $0.05190/h × 730 h ≈ **$37.9/월**(베타 할인가). 할인이 끝나면 커질 수 있다.
  - ClickHouse: compute는 유휴 시 0, 저장은 상시. 활동 시간 × 단가(서울 Basic/Scale 단가는 실행일 확인). egress는 측정으로 과금 여부 확인.
  - (선택) NAT: $0.059/h × 730 ≈ $43.1 + EIP $3.65 + $0.059/GB.
- **B. Aurora Serverless v2 + Data API (기준선)**
  - 활동 시간 × (평균 ACU) × $0.20 + 저장 GB × $0.12 + I/O × $0.24/100만 + N × $0.42/100만(Data API) + 비밀 월 요금.
  - "활동 시간"은 마지막 요청 뒤 300초까지 깨어 있으므로 트래픽 모양에 따라 달라진다(7.2).
- **C. Aurora DSQL (기준선)**
  - N × (DPU/요청) × $0.00001 − 무료 10만 DPU + 저장 GB × $0.40 − 무료 1 GB.
- **D. 상시 EC2 API 서버 (문서 단가만, 측정 안 함)**
  - t4g.small $0.0208/h × 730 ≈ $15.2 + IPv4 $3.65 + gp3 8 GB ≈ $0.73 → **약 $19.6/월**(t4g.nano면 약 $8.2). 로드밸런서 없이 공인 IP 하나. 처리량 한계는 측정하지 않으므로 "1억 건/월도 감당한다"는 가정임을 표에 적는다. 이 구성은 Postgres IP 필터를 그 /32로 좁힐 수 있다(NAT 불필요).
- **E. DynamoDB·Athena (문서 단가만)**: 데이터 모델이 달라 같은 코드로 재지 않는다. 같은 요청 수를 읽기·쓰기 단위로 단순 환산한 값만 참고로 적는다.

### 7.2 트래픽 모양

| 모양 | 정의 | B의 활동 시간 |
|---|---|---|
| 드문드문 | 월 10만 건, 하루 2시간 안에 몰림 | 약 (2 h + 5분) × 30일 |
| 꾸준함 | 월 1,000만 건, 고르게(평균 약 4건/초) | 730 h(5분 넘게 비는 때가 없음) |
| 많음 | 월 1억 건, 고르게(평균 약 38건/초) | 730 h |

각 모양 × 구성(A, A+NAT, B, C, D, + 참고 E)의 월 비용 표를 만들고, A 대비 손익분기(요청 수/월)를 구한다.

### 7.3 가설 (측정으로 확인하거나 반박)

2026-10-11에 문서 단가와 가정(256 MB, 요청당 청구 100 ms, 요청당 로그 약 300바이트)으로 계산한 추정이다. 측정값이 아니다.

- 드문드문: B·C·E가 월 몇 달러로 가장 싸고, A는 Postgres 고정비 $37.9가 거의 전부다.
- 꾸준함: B는 늘 깨어 있어 0.5 ACU만 잡아도 약 $73/월 이상으로 A보다 비싸다. C는 DPU/요청에 달렸다(1 DPU/요청이면 1,000만 건에 약 $100).
- 많음: Lambda 변동비(무료 넘으면 100만 건당 약 $0.76, 그중 약 30%가 로그)가 커져, **월 약 3,000만 건 근처에서 D(약 $20)가 A의 Lambda 부분보다 싸진다**.
- IP를 좁혀야 하면: A+NAT(고정 약 $47)보다 D가 싸고, B·C·E는 IAM이라 NAT가 필요 없다.

보고할 값: 경로별 청구 ms·GB-s/요청·로그 바이트/요청(측정), L-AUR의 깨어나는 시간과 ACU-s/요청, L-DSQL의 DPU/요청, 7.2 표, 손익분기 지점, 그리고 위 가설 각각이 맞았는지.

## 8. 공유 서비스 안전 규칙 (Seoul)

- **Managed Postgres `seoul-oltp`** 에는 라이브 데모(bikemap, ny-citi-bike)와 분당 pg_cron 작업 3개, CDC 슬롯 2개가 있다(2026-10-02 기준).
  - 서비스를 삭제하거나 크기를 바꾸지 않는다. 기존 DB·확장·cron·publication·foreign server는 건드리지 않는다. 이 실험은 **새 DB `mpg_hols_lambda`와 전용 사용자** 안에서만.
  - 기존 pg_clickhouse 객체는 0.3이고 bikemap이 의존한다. `ALTER EXTENSION` 금지.
  - 실행 전후 스냅샷(스키마·확장·cron·publication·foreign server) diff.
  - 동시성 상한 100(단계 4). PgBouncer 설정 변경 금지.
- **ClickHouse Cloud `Seoul`**: 전용 DB `mpg_hols_lambda`와 전용 사용자만. `default`나 다른 DB 사용 금지. idle·크기 설정 변경 금지.
- **기준선 자원**(Aurora 클러스터, DSQL 클러스터, 비밀)은 이 실험 전용으로 새로 만들고 끝나면 지운다. 계정에 있는 다른 Aurora·RDS 자원은 건드리지 않는다. Aurora는 퍼블릭 접근 없이 Data API로만 쓴다.
- **보안 설정 변경**(IP 필터, API key 허용 목록)은 소유자 승인 후, 실행 시간 동안만, 끝나면 원상복구하고 기록.
- 자동 승인 분류기가 막는 동작(비밀번호를 VM에서 가져오기, 공유 서비스의 테이블 삭제 등)은 우회하지 않고 소유자에게 실행할 명령 한 줄을 건넨다.

## 9. 예산

- 승인 받을 것: AWS 쪽 **$15 상한**. 예상(추정): Lambda·로그·SSM은 무료 사용량 안팎, 기준선 Aurora는 실행 6시간 × 최대 2 ACU × $0.20 ≈ $2.4 + 비밀·저장 몇 센트, DSQL은 무료 10만 DPU 안팎(넘어도 단계 4-b 기준 $1 미만 예상). NAT 경로를 하면 시간당 $0.059 + EIP가 더해진다. ClickHouse·Postgres는 기존 서비스라 늘어나는 것은 ClickHouse 활동 시간뿐.
- AWS Budgets 경보는 쓰지 않는다(소유자 계정에서 쓰지 않음, 2026-10-11 — Cost Explorer와 같음). 대신 단계가 끝날 때마다 Price List 단가 × 그때까지의 사용량으로 누적 비용을 추정해 로그에 남기고, 상한에 가까워지면 멈추고 묻는다. 자원은 단계가 끝나면 바로 지운다.
- 실행이 끊기면 정리(단계 6)부터.

## 10. 저장소에 들어갈 것

```
managed-postgres/lambda-direct/
  PLAN.md            이 문서
  README.md          영어 먼저, ## English / ## 한국어 (구현 때)
  RESULTS.md         §11 양식 (실행 뒤)
  config.env.example 호스트·사용자 자리표시자만 (호스트는 <service>.<id>.c0.<region>.aws.pg.clickhouse.cloud 형식)
  .gitignore         config.env, logs/, terraform/.terraform/, *.tfstate*, *.zip, dist/
  terraform/         main.tf variables.tf outputs.tf (+ nat.tf, aurora.tf, dsql.tf — 각각 count로 꺼 둠)
  function/          index.mjs package.json package-lock.json
  sql/               00-pg-setup.sql 01-ch-setup.sql 02-fdw.sql 10-aurora-setup.sql 20-dsql-setup.sql 99-cleanup.sql
  scripts/           00-preflight.sh 10-load.sh 20-functional.sh 30-latency.py 35-aurora-wake.py 40-concurrency.py 45-usage.py 90-snapshot.sh 95-cost-estimate.py 99-teardown.sh
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
| path | cold init | cold first call | of which connect | warm p50 | p95 | p99 | billed ms p50 |
| CH idle wake | L-CH: … | L-QE: … |
| Aurora resume (S7) | run 1/2/3 client s | server s | events |

## Concurrency
| path | concurrency | PG backends | PgBouncer cl_active/cl_waiting/sv_active | errors | retries | p95 |

## Usage per request (step 4-b)
| path | GB-s | log bytes | ACU-s (L-AUR) | DPU (L-DSQL) | Data API calls |

## Network (Q7)
| option | worked | extra latency | monthly fixed cost |

## Cost by traffic shape (PLAN §7.2; inputs measured, prices from §2)
| shape | A | A+NAT | B Aurora+Data API | C DSQL | D EC2 (doc only) | E DynamoDB (doc only) |
| break-even vs A (requests/month) | … |
| hypotheses in §7.3 | held / did not hold, with the numbers |

## Conclusions (facts only)
## Cost of the run (AWS: estimate from Price List × measured usage — no Cost Explorer access; ClickHouse: Usage Cost API for the run window)
```

## 12. 작업 분할 (구현 세션용)

한 작업 = 한 커밋 크기, 새 sub-agent 하나. 각 작업은 `allowed`(바꿔도 되는 파일)와 `verify`(통과해야 할 명령)를 가진다. 설계나 문서의 주장을 바꿔야 하면 구현자가 아니라 리드가 이 문서를 고친다.

| # | 작업 | allowed | verify |
|---|---|---|---|
| T1 | 뼈대: `.gitignore`, `config.env.example`, `lab.yaml`(runner·게시 키 없음) | 해당 3개 | `git check-ignore config.env logs/x terraform/terraform.tfstate`가 모두 무시됨, gitleaks 통과 |
| T2 | Lambda 코드: 경로 8개(L-AUR·L-DSQL 포함), 연결 재사용, 시간 측정 JSON | `function/` | 로컬: `node --check`, Postgres·ClickHouse 컨테이너(`extensions/pg-clickhouse-lab/docker-compose.yml` 재사용 가능)로 핸들러 직접 호출 테스트. L-AUR·L-DSQL은 로컬 대체가 없으므로 SDK 호출을 가짜 객체로 바꾼 단위 테스트만 |
| T3 | SQL·적재 스크립트 | `sql/`, `scripts/10-load.sh` | 로컬 컨테이너에서 생성·적재·삭제 1회. DSQL용 적재는 트랜잭션당 1,000행으로 나뉘는지 테스트 |
| T4 | Terraform(`nat`·`aurora`·`dsql` count 포함) | `terraform/` | `terraform fmt -check`, `terraform validate`, 세 count를 켠 `terraform plan`과 끈 `plan`(apply 금지) |
| T5 | 측정 스크립트(기능·지연·Aurora 깨어나기·동시성·요청당 사용량·스냅샷·비용 추정·정리) | `scripts/` | `--dry-run`이 호출 목록만 출력, `shellcheck`, `python -m py_compile`, `95-cost-estimate.py`가 §7.3의 가정값을 넣으면 §7.3과 같은 숫자를 내는지 |
| T6 | README(영·한) | `README.md` | 두 언어 절이 같은 내용, "Verified" 줄 없음(실행 전) |
| T7 | 실행(소유자 승인 후) → RESULTS.md, 정리, 다음 날 비용 | `RESULTS.md`, README 검증 줄 | 단계 6의 diff가 비어 있음, 자원 0개 |

## 13. 소유자가 정할 것

1. NAT 경로(단계 5)를 할지 — 하면 NAT 시간 요금이 붙는다.
2. L-QEPG(Q5, Query API Endpoint → `postgresql()`)를 할지.
3. 단계 0에서 Postgres IP 필터가 막혀 있으면 (a)/(b)/(c) 중 무엇.
4. 결과를 notes 사이트 lab 카드로 게시할지(`lab.yaml`의 `web`).
5. AWS 서버리스 기준선(Q8)을 할지, 한다면 L-AUR·L-DSQL 둘 다인지 하나인지. (2026-10-11 소유자 요청으로 계획에 넣음. 실행 여부는 지출 승인 때 함께 정한다.)
6. Aurora 24시간 넘는 깊은 잠 깨어나기를 잴지 — 하면 Aurora 클러스터를 하루 넘게 남겨 둔다(그동안 compute 0, 저장·비밀만 과금).
