# ClickHouse Managed Postgres Hands-on Labs

[English](#english) | [한국어](#한국어)

## English

Hands-on labs for ClickHouse Managed Postgres and the `pg_clickhouse` extension: provisioning, PostGIS and vector search beside ClickHouse, and pushing analytics down from Postgres to ClickHouse.

> This repository was split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) on the `pre-split-2026-10` tag, with history. The last version of these labs in the original repository: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

### 🐘 Managed Postgres (`managed-postgres/`)

| Lab | What it covers |
|-----|----------------|
| [managed-postgres/provisioning](managed-postgres/provisioning/) | Create a service over the Cloud API, connect and verify |
| [managed-postgres/postgis-fdw-bike](managed-postgres/postgis-fdw-bike/) | PostGIS beside 24M Seoul bike trips: geometry stays in Postgres, aggregates push down to ClickHouse through `pg_clickhouse` |
| [managed-postgres/ny-citi-bike-workshop](managed-postgres/ny-citi-bike-workshop/) | The same split on a live New York Citi Bike feed — a self-service workshop in [its own repository](https://github.com/litkhai/lightweight-workshop-ny-citi-bike) |
| [managed-postgres/vector-search](managed-postgres/vector-search/) | pgvector, VectorChord and ClickHouse's vector index over the same million embeddings, compared at matched recall |

### 🧩 Extensions (`extensions/`)

| Lab | What it covers |
|-----|----------------|
| [extensions/pg-clickhouse-lab](extensions/pg-clickhouse-lab/) | `pg_clickhouse` on local Docker: querying ClickHouse from PostgreSQL |

### 🔗 Related repositories

| Repository | What it is |
|---|---|
| [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) | Core ClickHouse hands-on labs |
| [litkhai/clickhouse-hols — `local/pg-analytics`](https://github.com/litkhai/clickhouse-hols/tree/main/local/pg-analytics) | Self-hosted pg_lake / pg_duckdb / pg_clickhouse benchmark (stays in the core repo) |

### ✅ Repository checks

```bash
git config core.hooksPath .githooks
python3 .github/scripts/check_links.py
./.github/scripts/check_syntax.sh
```

### 📝 License

[MIT](LICENSE). Labs install ClickHouse and other software at run time under their own licences.

---

## 한국어

ClickHouse Managed Postgres와 `pg_clickhouse` 확장 실습 모음입니다. 서비스 생성, ClickHouse와 함께 쓰는 PostGIS·벡터 검색, 그리고 Postgres에서 ClickHouse로 분석 쿼리를 내려보내는 방법을 다룹니다.

> 이 저장소는 [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols)의 `pre-split-2026-10` 태그 시점에서 히스토리와 함께 분리했습니다. 원래 저장소에 있던 마지막 버전: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

### 🐘 Managed Postgres (`managed-postgres/`)

| 실습 | 내용 |
|-----|----------------|
| [managed-postgres/provisioning](managed-postgres/provisioning/) | Cloud API로 서비스 생성, 접속·검증 |
| [managed-postgres/postgis-fdw-bike](managed-postgres/postgis-fdw-bike/) | PostGIS와 2,400만 건의 따릉이 대여이력: 지오메트리는 Postgres에 남고 집계는 `pg_clickhouse`로 ClickHouse에 내려갑니다 |
| [managed-postgres/ny-citi-bike-workshop](managed-postgres/ny-citi-bike-workshop/) | 같은 분업을 뉴욕 Citi Bike 실시간 피드로 — [별도 저장소](https://github.com/litkhai/lightweight-workshop-ny-citi-bike)의 셀프 워크숍 |
| [managed-postgres/vector-search](managed-postgres/vector-search/) | 같은 100만 임베딩에 pgvector·VectorChord·ClickHouse 벡터 인덱스를 동일 recall에서 비교 |

### 🧩 확장 (`extensions/`)

| 실습 | 내용 |
|-----|----------------|
| [extensions/pg-clickhouse-lab](extensions/pg-clickhouse-lab/) | 로컬 Docker의 `pg_clickhouse`: PostgreSQL에서 ClickHouse 조회 |

### 🔗 관련 저장소

| 저장소 | 설명 |
|---|---|
| [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) | ClickHouse 핵심 실습 |
| [litkhai/clickhouse-hols — `local/pg-analytics`](https://github.com/litkhai/clickhouse-hols/tree/main/local/pg-analytics) | 자체 호스팅 pg_lake / pg_duckdb / pg_clickhouse 벤치마크 (코어 레포에 남음) |

### ✅ 저장소 검사

```bash
git config core.hooksPath .githooks
python3 .github/scripts/check_links.py
./.github/scripts/check_syntax.sh
```

### 📝 라이선스

[MIT](LICENSE). 실습이 실행 시점에 설치하는 소프트웨어는 각자의 라이선스를 따릅니다.
