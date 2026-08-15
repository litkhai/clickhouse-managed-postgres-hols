# ClickHouse Managed Postgres Lab

[English](#english) | [한국어](#한국어)

---

## English

> **Status: in progress.** Two labs are written and were verified against a live
> service on 2026-08-15 — [`provisioning/`](provisioning/) and
> [`postgis-fdw-bike/`](postgis-fdw-bike/). The remaining areas below are drafted
> from the product documentation and not written yet.

Hands-on labs for [ClickHouse Managed Postgres](https://clickhouse.com/docs/products/managed-postgres/overview)
— the managed Postgres service ClickHouse runs in partnership with Ubicloud,
using NVMe storage collocated with compute rather than network-attached
volumes, with integration back into ClickHouse for analytics.

It is a distinct product rather than a ClickHouse Cloud integration, which is
why it sits at the top level next to `chc/` instead of inside it.

### 📋 Scope

Areas taken from the product's documentation. Ticked ones exist.

| Area | What a lab covers |
|------|-------------------|
| [`provisioning/`](provisioning/) ✅ | Create a service over the Cloud API; connect and verify |
| [`postgis-fdw-bike/`](postgis-fdw-bike/) ✅ | PostGIS geometry beside 24M Seoul bike trips, replicated to ClickHouse by ClickPipes and read back through `pg_clickhouse`. A dashboard shows, per query, which side answered — and the plan proving it |
| [`ny-citi-bike-workshop/`](ny-citi-bike-workshop/) ↗ | The same split on a **live** feed, across both managed products — a self-service workshop in [its own repository](https://github.com/litkhai/lightweight-workshop-ny-citi-bike) |
| Operations | Read replicas, scaling, high availability, backup and restore |
| Monitoring | Metrics, query insights, Prometheus |

`pg_clickhouse`, the ClickHouse integration and the ClickPipes/PeerDB migration
path are all exercised inside `postgis-fdw-bike/` rather than getting labs of
their own — the point of each is easier to see against real data than in
isolation. The extension's own
[tutorial](https://clickhouse.com/docs/products/managed-postgres/extensions/pg_clickhouse/tutorial)
covers the minimal version.

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

> **상태: 진행 중.** 랩 두 개를 작성했고 2026-08-15에 실제 서비스로
> 검증했습니다 — [`provisioning/`](provisioning/)과
> [`postgis-fdw-bike/`](postgis-fdw-bike/). 아래 나머지 영역은 제품 문서를 보고
> 잡은 초안이며 아직 작성하지 않았습니다.

[ClickHouse Managed Postgres](https://clickhouse.com/docs/products/managed-postgres/overview)
실습입니다. ClickHouse가 Ubicloud와 함께 운영하는 관리형 Postgres 서비스로,
네트워크 연결 볼륨 대신 컴퓨트와 물리적으로 같이 놓인 NVMe 스토리지를 쓰고,
분석을 위해 ClickHouse와 연동됩니다.

ClickHouse Cloud의 연동 기능이 아니라 별개 제품이라, `chc/` 안이 아니라 그
옆 최상위에 두었습니다.

### 📋 범위

제품 문서를 보고 뽑은 주제입니다. 체크 표시된 것이 작성돼 있습니다.

| 영역 | 다루는 내용 |
|------|-----------|
| [`provisioning/`](provisioning/) ✅ | Cloud API로 서비스 생성, 접속·검증 |
| [`postgis-fdw-bike/`](postgis-fdw-bike/) ✅ | PostGIS 지오메트리와 2,400만 건의 따릉이 대여이력. ClickPipes로 ClickHouse에 복제하고 `pg_clickhouse`로 되읽습니다. 쿼리마다 어느 쪽이 답했는지와 그 근거인 실행 계획을 보여주는 대시보드 포함 |
| [`ny-citi-bike-workshop/`](ny-citi-bike-workshop/) ↗ | 같은 분업을 **실시간** 피드로, 두 관리형 제품에 걸쳐 — [별도 저장소](https://github.com/litkhai/lightweight-workshop-ny-citi-bike)의 자율 실습 워크숍 |
| 운영 | 읽기 복제본, 스케일링, 고가용성, 백업·복구 |
| 모니터링 | 메트릭, 쿼리 인사이트, Prometheus |

`pg_clickhouse`, ClickHouse 연동, ClickPipes/PeerDB 마이그레이션 경로는 별도 랩
대신 `postgis-fdw-bike/` 안에서 함께 다룹니다 — 각각의 요점이 고립된 예제보다
실제 데이터 위에서 훨씬 잘 보이기 때문입니다. 최소 예제는 확장 자체의
[튜토리얼](https://clickhouse.com/docs/products/managed-postgres/extensions/pg_clickhouse/tutorial)에
있습니다.

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
