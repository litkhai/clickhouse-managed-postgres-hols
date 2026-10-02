# Provisioning — ClickHouse Managed Postgres

[English](#english) | [한국어](#한국어)

---

## English

Creating a Managed Postgres service through the ClickHouse Cloud API, and
confirming you can reach it.

**Verified 2026-10-02** with `01-connect-test.sh` against a live service in `ap-northeast-2`. It was an existing `r6gd.large`.

| Check | Result |
|---|---|
| Server | **PostgreSQL 18.6** |
| TLS | TLS 1.3 |
| `wal_level` | `logical` |
| `max_connections` | 500 |
| `pg_clickhouse` | 0.10 available, 0.3 installed |
| `pg_stat_ch` | 0.3 installed |

It was first verified on 2026-08-15, on PostgreSQL 18.4.

The API shapes below come from the live OpenAPI spec at `https://api.clickhouse.cloud/v1`, read 2026-10-01.

**Creating and deleting a service has not been run against the live API.** `00-create-service.sh` and `99-delete-service.sh` were tested only against a local mock of it, and both verifications used a service that already existed.

### Files

| File | Role |
|------|------|
| `config.env.example` | Template. Copy to `config.env`, which is gitignored |
| `00-create-service.sh` | Creates a service over the API. It writes `config.env` (mode 600) without printing the password, then waits for `running`. `--dry-run` only prints the request. Tested against a mock only |
| `01-connect-test.sh` | Connects, reports the server, and does a write round trip |
| `99-delete-service.sh` | Deletes the service named by `PG_SERVICE_ID` in `config.env`, waits until it is gone, then renames `config.env`. Tested against a mock only |

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

The script sends the same request. It takes the API key from the environment, from `CHC_ENV_FILE`, or from `config.env`, and passes it to curl on stdin rather than on the command line:

```bash
./00-create-service.sh --dry-run                                   # print the body, send nothing
./00-create-service.sh --region ap-northeast-2 --size m6gd.large   # asks before creating
```

Request fields, from the spec (read 2026-10-01):

| Field | Required | Values |
|-------|----------|--------|
| `name` | yes | Alphanumeric with spaces, up to 50 characters. `PATCH …/{pgId}` can change it, along with `size`, `haType` and `tags` |
| `provider` | yes | `aws`, `gcp` |
| `region` | yes | Free-form string; no enum in the spec, so an invalid one only fails on the call |
| `size` | yes | 143 VM sizes — AWS `c6gd`, `i7i`, `i7ie`, `i8g`, `i8ge`, `m6gd`, `m6id`, `m8gd`, `r6gd`, `r6id`, `r8gd`; GCP `c4a`, `c4`, `c4d`, `z3` |
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
GET    /v1/organizations/{orgId}/postgres/prometheus
GET    /v1/organizations/{orgId}/postgres/{pgId}             details, incl. state
PATCH  /v1/organizations/{orgId}/postgres/{pgId}             name, size, haType, tags
PATCH  /v1/organizations/{orgId}/postgres/{pgId}/state       start / stop
PATCH  /v1/organizations/{orgId}/postgres/{pgId}/password    rotate the superuser password
GET    /v1/organizations/{orgId}/postgres/{pgId}/caCertificates
GET    /v1/organizations/{orgId}/postgres/{pgId}/metrics     time series
GET    /v1/organizations/{orgId}/postgres/{pgId}/prometheus
GET    /v1/organizations/{orgId}/postgres/{pgId}/logs
GET    /v1/organizations/{orgId}/postgres/{pgId}/slowQueryPatterns[/{queryId}]
GET|PATCH|POST /v1/organizations/{orgId}/postgres/{pgId}/config
POST   /v1/organizations/{orgId}/postgres/{pgId}/readReplica
POST   /v1/organizations/{orgId}/postgres/{pgId}/restoredService
DELETE /v1/organizations/{orgId}/postgres/{pgId}             delete
```

The listing does not return the hostname or the password. `GET …/{pgId}` returns the hostname and username. Per the spec, the password and `connectionString` are "only returned when the service is created or its password is reset" and are not guaranteed even then. So an existing service's password has to come from wherever it was saved at creation.

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

This is the 2026-10-02 run. That service already had `postgis` and `pg_cron` installed by other labs.

```
host    : <service>.<id>.c0.ap-northeast-2.aws.pg.clickhouse.cloud
port    : 5432   user: postgres   sslmode: require

── server ─────────────────────────────────────────
version | 18.6 (Ubuntu 18.6-1.pgdg22.04+2)
superuser | on
read_only | false
tls | TLSv1.3
wal_level | logical
max_conns | 500

── extensions ─────────────────────────────────────
pg_clickhouse | 0.10 | 0.3
pg_cron | 1.6 | 1.6
pg_stat_ch | 0.3 | 0.3
plpgsql | 1.0 | 1.0
postgis | 3.6.4 | 3.6.4

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
- **`pg_clickhouse` is available but not installed** on a new service (observed
  2026-08-15). `CREATE EXTENSION` when a lab needs it, rather than assuming it is
  there.
- **An installed extension does not follow the service's upgrades.** On
  2026-10-02 the service offered `pg_clickhouse` 0.10, while the copy installed in
  August still reported 0.3. Functions added after 0.3, such as
  `clickhouse_query()`, are missing until `ALTER EXTENSION pg_clickhouse UPDATE`.

### Notes

- Costs money while it runs. `PATCH .../state` stops a service you want to keep
  but not pay for; `DELETE` removes it.
- `region` has no enum in the spec, so a typo is only caught by the API.
- The API accepts `aws` and `gcp` as providers (spec read 2026-10-01). The
  pricing page lists AWS regions only.

### 📄 License

[MIT](../../LICENSE) — same as the rest of the repository.

---

## 한국어

ClickHouse Cloud API로 Managed Postgres 서비스를 만드는 방법과, 실제로 접속이
되는지 확인하는 스크립트입니다.

**2026-10-02 검증** — `ap-northeast-2`의 실제 서비스에 `01-connect-test.sh`로 접속해 확인했습니다. 이미 있던 `r6gd.large` 서비스입니다.

| 항목 | 결과 |
|---|---|
| 서버 | **PostgreSQL 18.6** |
| TLS | TLS 1.3 |
| `wal_level` | `logical` |
| `max_connections` | 500 |
| `pg_clickhouse` | 0.10 사용 가능, 0.3 설치됨 |
| `pg_stat_ch` | 0.3 설치됨 |

처음 검증은 2026-08-15, PostgreSQL 18.4에서였습니다.

아래 API 스키마는 `https://api.clickhouse.cloud/v1`의 라이브 OpenAPI 스펙에서 가져왔고, 2026-10-01에 읽었습니다.

**서비스 생성·삭제는 실제 API로 실행하지 않았습니다.** `00-create-service.sh`와 `99-delete-service.sh`는 로컬에 띄운 가짜 API로만 시험했고, 두 번의 검증 모두 이미 있던 서비스를 썼습니다.

### 파일

| 파일 | 역할 |
|------|------|
| `config.env.example` | 템플릿. `config.env`로 복사해서 사용하며 그 파일은 gitignore됩니다 |
| `00-create-service.sh` | API로 서비스를 만듭니다. 비밀번호를 출력하지 않고 `config.env`(권한 600)에 쓴 뒤 `running`이 될 때까지 기다립니다. `--dry-run`은 요청만 보여 줍니다. 가짜 API로만 시험함 |
| `01-connect-test.sh` | 접속해서 서버 정보를 출력하고 쓰기까지 왕복 확인 |
| `99-delete-service.sh` | `config.env`의 `PG_SERVICE_ID` 서비스를 삭제하고 사라질 때까지 기다린 뒤 `config.env` 이름을 바꿉니다. 가짜 API로만 시험함 |

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

스크립트도 같은 요청을 보냅니다. API 키는 환경 변수, `CHC_ENV_FILE`, `config.env` 중 한 곳에서 읽고, curl에는 명령행 인자가 아니라 표준 입력으로 넘깁니다.

```bash
./00-create-service.sh --dry-run                                   # 본문만 출력, 전송 안 함
./00-create-service.sh --region ap-northeast-2 --size m6gd.large   # 만들기 전에 확인을 받음
```

스펙 기준 요청 필드(2026-10-01 조회):

| 필드 | 필수 | 값 |
|------|------|-----|
| `name` | ✔ | 영숫자와 공백, 50자까지. `PATCH …/{pgId}`로 `size`·`haType`·`tags`와 함께 바꿀 수 있음 |
| `provider` | ✔ | `aws`, `gcp` |
| `region` | ✔ | 자유 문자열. 스펙에 enum이 없어 잘못된 값은 호출해야 알 수 있음 |
| `size` | ✔ | 143종 — AWS `c6gd`, `i7i`, `i7ie`, `i8g`, `i8ge`, `m6gd`, `m6id`, `m8gd`, `r6gd`, `r6id`, `r8gd`; GCP `c4a`, `c4`, `c4d`, `z3` |
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
GET    /v1/organizations/{orgId}/postgres/prometheus
GET    /v1/organizations/{orgId}/postgres/{pgId}             상세 (state 포함)
PATCH  /v1/organizations/{orgId}/postgres/{pgId}             name, size, haType, tags
PATCH  /v1/organizations/{orgId}/postgres/{pgId}/state       시작 / 정지
PATCH  /v1/organizations/{orgId}/postgres/{pgId}/password    superuser 비밀번호 교체
GET    /v1/organizations/{orgId}/postgres/{pgId}/caCertificates
GET    /v1/organizations/{orgId}/postgres/{pgId}/metrics     시계열 메트릭
GET    /v1/organizations/{orgId}/postgres/{pgId}/prometheus
GET    /v1/organizations/{orgId}/postgres/{pgId}/logs
GET    /v1/organizations/{orgId}/postgres/{pgId}/slowQueryPatterns[/{queryId}]
GET|PATCH|POST /v1/organizations/{orgId}/postgres/{pgId}/config
POST   /v1/organizations/{orgId}/postgres/{pgId}/readReplica
POST   /v1/organizations/{orgId}/postgres/{pgId}/restoredService
DELETE /v1/organizations/{orgId}/postgres/{pgId}             삭제
```

목록 응답에는 호스트명과 비밀번호가 없습니다. `GET …/{pgId}`는 호스트명과 사용자명을 줍니다. 스펙에 따르면 비밀번호와 `connectionString`은 "서비스를 만들 때나 비밀번호를 재설정할 때만" 돌려주고, 그때도 반드시 온다는 보장은 없습니다. 그래서 기존 서비스의 비밀번호는 만들 때 저장해 둔 곳에서 가져와야 합니다.

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
- **새 서비스에서 `pg_clickhouse`는 사용 가능하지만 미설치 상태**입니다(2026-08-15
  관찰). 필요한 랩에서 `CREATE EXTENSION`으로 켜야 하며, 이미 있다고 가정하면
  안 됩니다.
- **설치된 확장은 서비스 업그레이드를 따라가지 않습니다.** 2026-10-02에 서비스는
  `pg_clickhouse` 0.10을 제공했지만, 8월에 설치한 확장은 여전히 0.3이었습니다.
  `clickhouse_query()`처럼 0.3 이후에 추가된 함수는 `ALTER EXTENSION pg_clickhouse UPDATE`
  전까지 없습니다.

### 참고

- 실행 중에는 과금됩니다. 유지하되 비용을 줄이려면 `PATCH .../state`로 정지하고,
  아예 없앨 거면 `DELETE`를 씁니다.
- `region`에는 enum이 없어서 오타는 API 호출에서만 걸립니다.
- API는 provider로 `aws`와 `gcp`를 받습니다(스펙 2026-10-01 조회). 요금 페이지에는
  AWS 리전만 나옵니다.

### 📄 라이선스

[MIT](../../LICENSE) — 저장소 전체와 동일합니다.
