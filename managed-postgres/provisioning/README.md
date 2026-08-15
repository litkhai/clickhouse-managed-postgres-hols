# Provisioning — ClickHouse Managed Postgres

[English](#english) | [한국어](#한국어)

---

## English

Creating a Managed Postgres service through the ClickHouse Cloud API, and
confirming you can reach it.

**Verified 2026-08-15** against a live service in `ap-northeast-2`: server
**PostgreSQL 18.4**, TLS 1.3, `wal_level = logical`, `max_connections = 500`,
`pg_clickhouse` 0.3 available and `pg_stat_ch` 0.3 installed. The API shapes
below come from the live OpenAPI spec at `https://api.clickhouse.cloud/v1`;
the create call itself is **documented but not executed here** — the service
tested against already existed, and creating one costs money.

### Files

| File | Role |
|------|------|
| `config.env.example` | Template. Copy to `config.env`, which is gitignored |
| `01-connect-test.sh` | Connects, reports the server, and does a write round trip |

### Creating a service over the API

Postgres services live under the same ClickHouse Cloud API as analytics
services, with the same [organization API key](https://clickhouse.com/docs/cloud/manage/openapi)
as basic auth.

```bash
KEY_ID=...        # organization API key
KEY_SECRET=...
ORG_ID=...        # Console → Organization details

curl -s --user "$KEY_ID:$KEY_SECRET" \
  -H 'Content-Type: application/json' \
  "https://api.clickhouse.cloud/v1/organizations/$ORG_ID/postgres" \
  -d '{
        "name":            "seoul-oltp",
        "provider":        "aws",
        "region":          "ap-northeast-2",
        "size":            "m6gd.large",
        "postgresVersion": "18",
        "haType":          "none"
      }' | jq
```

Request fields, from the spec:

| Field | Required | Values |
|-------|----------|--------|
| `name` | yes | Alphanumeric with spaces. Immutable |
| `provider` | yes | `aws` only |
| `region` | yes | Free-form string; no enum in the spec, so an invalid one only fails on the call |
| `size` | yes | 80 instance types, `c6gd.large` … `r8gd.48xlarge` |
| `postgresVersion` | no | `18`, `17` |
| `haType` | no | `none`, `async`, `sync` |
| `pgConfig`, `pgBouncerConfig`, `tags` | no | Postgres and PgBouncer runtime settings |

> **The response contains the password.** Along with `connectionString`,
> `username` and `hostname`. Capture it into `config.env` or a secret store on
> the spot — do not tee the response into a file that gets committed, and do
> not paste it into an issue. `PATCH .../{postgresId}/password` rotates it if
> it does leak.

The other endpoints on the same path:

```
GET    /v1/organizations/{orgId}/postgres                    list
GET    /v1/organizations/{orgId}/postgres/{pgId}             details, incl. state
PATCH  /v1/organizations/{orgId}/postgres/{pgId}/state       start / stop
PATCH  /v1/organizations/{orgId}/postgres/{pgId}/password    rotate the superuser password
GET    /v1/organizations/{orgId}/postgres/{pgId}/caCertificates
GET    /v1/organizations/{orgId}/postgres/{pgId}/metrics     time series
GET    /v1/organizations/{orgId}/postgres/{pgId}/slowQueryPatterns
POST   /v1/organizations/{orgId}/postgres/{pgId}/readReplica
DELETE /v1/organizations/{orgId}/postgres/{pgId}             delete
```

Terraform covers the same ground with the `clickhouse_postgres_service`
resource in provider ≥ 3.21.0, which is
[alpha](https://clickhouse.com/docs/products/managed-postgres/terraform).

### Connecting

```bash
cp config.env.example config.env
$EDITOR config.env          # host, password from the console or the create response
./01-connect-test.sh
```

`psql` runs in a container, so nothing needs installing on the host. Output is
masked: the hostname carries the service name and id, so the script prints
`<service>.<id>.…` rather than the real thing.

```
host    : <service>.<id>.c0.ap-northeast-2.aws.pg.clickhouse.cloud
port    : 5432   user: postgres   sslmode: require

── server ─────────────────────────────────────────
version   | 18.4 (Ubuntu 18.4-1.pgdg22.04+1)
superuser | on
read_only | false
tls       | TLSv1.3
wal_level | logical
max_conns | 500

── extensions ─────────────────────────────────────
pg_clickhouse | 0.3 | -
pg_stat_ch    | 0.3 | 0.3
plpgsql       | 1.0 | 1.0

OK: connected, queried and wrote.
```

### What the connection tells you

- **Standard Postgres 18.** Not a fork or a wire-compatible layer — an ordinary
  `psql` connects and `pg_stat_ssl`, temp tables and `current_setting()` all
  behave normally.
- **TLS is mandatory.** The service refuses plaintext. `require` encrypts
  without checking the certificate; for `verify-full`, fetch the CA from the
  `caCertificates` endpoint.
- **`wal_level = logical` out of the box**, so logical replication and ClickPipes
  need no restart to enable.
- **`pg_clickhouse` is available but not installed.** `CREATE EXTENSION` when a
  lab needs it, rather than assuming it is there.

### Notes

- Costs money while it runs. `PATCH .../state` stops a service you want to keep
  but not pay for; `DELETE` removes it.
- `region` has no enum in the spec, so a typo is only caught by the API.
- Public beta, AWS only, at time of writing.

### 📄 License

[MIT](../../LICENSE) — same as the rest of the repository.

---

## 한국어

ClickHouse Cloud API로 Managed Postgres 서비스를 만드는 방법과, 실제로 접속이
되는지 확인하는 스크립트입니다.

**2026-08-15 검증** — `ap-northeast-2`의 실제 서비스에 접속해 확인했습니다.
**PostgreSQL 18.4**, TLS 1.3, `wal_level = logical`, `max_connections = 500`,
`pg_clickhouse` 0.3 사용 가능, `pg_stat_ch` 0.3 설치됨. 아래 API 스키마는
`https://api.clickhouse.cloud/v1`의 라이브 OpenAPI 스펙에서 가져온 것이며,
**생성 호출 자체는 문서화만 하고 실행하지 않았습니다** — 테스트한 서비스는 이미
존재하던 것이고, 새로 만들면 과금됩니다.

### 파일

| 파일 | 역할 |
|------|------|
| `config.env.example` | 템플릿. `config.env`로 복사해서 사용하며 그 파일은 gitignore됩니다 |
| `01-connect-test.sh` | 접속해서 서버 정보를 출력하고 쓰기까지 왕복 확인 |

### API로 서비스 생성

Postgres 서비스는 분석용 서비스와 같은 ClickHouse Cloud API 아래에 있고, 인증도
같은 [조직 API 키](https://clickhouse.com/docs/cloud/manage/openapi) basic auth입니다.

```bash
KEY_ID=...        # 조직 API 키
KEY_SECRET=...
ORG_ID=...        # 콘솔 → Organization details

curl -s --user "$KEY_ID:$KEY_SECRET" \
  -H 'Content-Type: application/json' \
  "https://api.clickhouse.cloud/v1/organizations/$ORG_ID/postgres" \
  -d '{
        "name":            "seoul-oltp",
        "provider":        "aws",
        "region":          "ap-northeast-2",
        "size":            "m6gd.large",
        "postgresVersion": "18",
        "haType":          "none"
      }' | jq
```

스펙 기준 요청 필드:

| 필드 | 필수 | 값 |
|------|------|-----|
| `name` | ✔ | 영숫자와 공백. 변경 불가 |
| `provider` | ✔ | `aws` 만 |
| `region` | ✔ | 자유 문자열. 스펙에 enum이 없어 잘못된 값은 호출해야 알 수 있음 |
| `size` | ✔ | 80종, `c6gd.large` … `r8gd.48xlarge` |
| `postgresVersion` | | `18`, `17` |
| `haType` | | `none`, `async`, `sync` |
| `pgConfig`, `pgBouncerConfig`, `tags` | | Postgres·PgBouncer 런타임 설정 |

> **응답에 비밀번호가 담겨 옵니다.** `connectionString`, `username`, `hostname`도
> 함께 옵니다. 받는 즉시 `config.env`나 시크릿 저장소로 옮기세요. 응답을 파일로
> 흘려 커밋하거나 이슈에 붙여넣지 마세요. 유출됐다면
> `PATCH .../{postgresId}/password`로 교체할 수 있습니다.

같은 경로의 나머지 엔드포인트:

```
GET    /v1/organizations/{orgId}/postgres                    목록
GET    /v1/organizations/{orgId}/postgres/{pgId}             상세 (state 포함)
PATCH  /v1/organizations/{orgId}/postgres/{pgId}/state       시작 / 정지
PATCH  /v1/organizations/{orgId}/postgres/{pgId}/password    superuser 비밀번호 교체
GET    /v1/organizations/{orgId}/postgres/{pgId}/caCertificates
GET    /v1/organizations/{orgId}/postgres/{pgId}/metrics     시계열 메트릭
GET    /v1/organizations/{orgId}/postgres/{pgId}/slowQueryPatterns
POST   /v1/organizations/{orgId}/postgres/{pgId}/readReplica
DELETE /v1/organizations/{orgId}/postgres/{pgId}             삭제
```

Terraform도 같은 범위를 지원합니다 — provider ≥ 3.21.0의
`clickhouse_postgres_service` 리소스이며
[alpha](https://clickhouse.com/docs/products/managed-postgres/terraform) 단계입니다.

### 접속

```bash
cp config.env.example config.env
$EDITOR config.env          # 콘솔이나 생성 응답에서 받은 호스트·비밀번호
./01-connect-test.sh
```

`psql`은 컨테이너로 실행하므로 호스트에 설치할 게 없습니다. 호스트명에 서비스
이름과 id가 들어 있어서, 출력은 `<service>.<id>.…` 로 마스킹됩니다.

### 접속으로 알 수 있는 것

- **표준 Postgres 18.** 포크나 와이어 호환 계층이 아니라, 일반 `psql`이 그대로
  붙고 `pg_stat_ssl`·임시 테이블·`current_setting()`이 모두 정상 동작합니다.
- **TLS 필수.** 평문 접속은 거부됩니다. `require`는 암호화만 하고 인증서를
  검증하지 않으니, `verify-full`이 필요하면 `caCertificates` 엔드포인트에서 CA를
  받으세요.
- **`wal_level = logical`이 기본**이라 논리 복제와 ClickPipes를 쓰는 데 재시작이
  필요 없습니다.
- **`pg_clickhouse`는 사용 가능하지만 미설치 상태.** 필요한 랩에서
  `CREATE EXTENSION`으로 켜야 하며, 이미 있다고 가정하면 안 됩니다.

### 참고

- 실행 중에는 과금됩니다. 유지하되 비용을 줄이려면 `PATCH .../state`로 정지하고,
  아예 없앨 거면 `DELETE`를 씁니다.
- `region`에는 enum이 없어서 오타는 API 호출에서만 걸립니다.
- 작성 시점 기준 public beta이며 AWS만 지원합니다.

### 📄 라이선스

[MIT](../../LICENSE) — 저장소 전체와 동일합니다.
