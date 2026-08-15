# ClickHouse Managed Postgres Lab

[English](#english) | [한국어](#한국어)

---

## English

> **Status: in progress.** [`provisioning/`](provisioning/) is written and was
> verified against a live service on 2026-08-15. The other areas below are
> drafted from the product documentation and not written yet.

Hands-on labs for [ClickHouse Managed Postgres](https://clickhouse.com/docs/products/managed-postgres/overview)
— the managed Postgres service ClickHouse runs in partnership with Ubicloud,
using NVMe storage collocated with compute rather than network-attached
volumes, with integration back into ClickHouse for analytics.

It is a distinct product rather than a ClickHouse Cloud integration, which is
why it sits at the top level next to `chc/` instead of inside it.

### 📋 Scope

Areas taken from the product's documentation. Only the ticked one exists so far.

| Area | What a lab would cover |
|------|------------------------|
| [`provisioning/`](provisioning/) ✅ | Create a service over the Cloud API; connect and verify — **done** |
| `pg_clickhouse` | The Postgres extension that reaches into ClickHouse — [tutorial](https://clickhouse.com/docs/products/managed-postgres/extensions/pg_clickhouse/tutorial) |
| ClickHouse integration | Moving and querying across the two engines |
| Migrations | ClickPipes, PeerDB, logical replication, `pg_dump`/`pg_restore` |
| Operations | Read replicas, scaling, high availability, backup and restore |
| Monitoring | Metrics, query insights, Prometheus |

### 🏠 Local development

The product is standard PostgreSQL, and ClickHouse documents
[developing against a local Postgres in Docker](https://clickhouse.com/docs/products/managed-postgres/local-development)
rather than a cloud deployment. Whatever can be exercised that way should be,
so the labs stay runnable without an account — matching how the rest of this
repository works. Anything that genuinely needs the managed service (NVMe
performance claims, read replicas, backups) has to say so in its own README.

### 🧱 Conventions

Follows the repository layout in the [root README](../README.md):
`00-setup.sh` to bring the environment up, then numbered `NN-<topic>.sh` runners
over matching `.sql` files, and a bilingual guide per lab. Every claim gets
verified against a running instance before it is written down.

### 📄 License

[MIT](../LICENSE) — same as the rest of the repository.

---

## 한국어

> **상태: 진행 중.** [`provisioning/`](provisioning/)은 작성 완료했고
> 2026-08-15에 실제 서비스로 검증했습니다. 아래 나머지 영역은 제품 문서를 보고
> 잡은 초안이며 아직 작성하지 않았습니다.

[ClickHouse Managed Postgres](https://clickhouse.com/docs/products/managed-postgres/overview)
실습입니다. ClickHouse가 Ubicloud와 함께 운영하는 관리형 Postgres 서비스로,
네트워크 연결 볼륨 대신 컴퓨트와 물리적으로 같이 놓인 NVMe 스토리지를 쓰고,
분석을 위해 ClickHouse와 연동됩니다.

ClickHouse Cloud의 연동 기능이 아니라 별개 제품이라, `chc/` 안이 아니라 그
옆 최상위에 두었습니다.

### 📋 범위

제품 문서를 보고 뽑은 주제입니다. 체크 표시된 것만 실제로 작성돼 있습니다.

| 영역 | 다룰 내용 |
|------|-----------|
| [`provisioning/`](provisioning/) ✅ | Cloud API로 서비스 생성, 접속·검증 — **완료** |
| `pg_clickhouse` | ClickHouse를 호출하는 Postgres 확장 — [튜토리얼](https://clickhouse.com/docs/products/managed-postgres/extensions/pg_clickhouse/tutorial) |
| ClickHouse 연동 | 두 엔진 사이의 데이터 이동과 조회 |
| 마이그레이션 | ClickPipes, PeerDB, 논리 복제, `pg_dump`/`pg_restore` |
| 운영 | 읽기 복제본, 스케일링, 고가용성, 백업·복구 |
| 모니터링 | 메트릭, 쿼리 인사이트, Prometheus |

### 🏠 로컬 개발

이 제품은 표준 PostgreSQL이고, ClickHouse도
[Docker 로컬 Postgres에서 개발하는 방법](https://clickhouse.com/docs/products/managed-postgres/local-development)을
문서화해 두었습니다. 그렇게 확인할 수 있는 것은 로컬로 다뤄서 계정 없이도
실행 가능하게 유지합니다 — 이 저장소의 다른 랩들과 같은 방식입니다. 관리형
서비스가 반드시 필요한 부분(NVMe 성능, 읽기 복제본, 백업)은 각 랩 README에
그렇게 명시합니다.

### 🧱 규약

[루트 README](../README.md)의 구성을 따릅니다. `00-setup.sh`로 환경을 띄우고,
번호가 붙은 `NN-<주제>.sh` 러너가 같은 이름의 `.sql`을 실행하며, 랩마다 영/한
가이드를 둡니다. 모든 서술은 실제로 띄운 인스턴스에서 확인한 뒤에 적습니다.

### 📄 라이선스

[MIT](../LICENSE) — 저장소 전체와 동일합니다.
