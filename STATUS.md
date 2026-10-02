# STATUS.md

**As of 2026-10-02** — split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## CI

`checks` runs one job on pull requests, `guard`: gitleaks and the repository-hygiene checks. `links` and `syntax` run only by hand (`gh workflow run checks.yml --ref <branch>`). Nothing runs on push to `main`; the pre-commit hook covers direct pushes.
GitHub secret scanning and push protection are on.

## Inventory

5 labs in the README tables; 0 single-language.

## Pins

Images the labs pull, pinned in the repository. Change a row only together with a re-run.

| Pin | Version | Why |
|---|---|---|
| `ghcr.io/clickhouse/pg_clickhouse:18-0.11.0@sha256:ce7a2b4b…` ([compose](extensions/pg-clickhouse-lab/docker-compose.yml)) | pg_clickhouse 0.11.0, PostgreSQL 18.6 | Latest pg_clickhouse release (2026-09-30). The tag alone names the extension but not the PG minor, because the image is rebuilt `FROM postgres:18-trixie`. The multi-arch index digest fixes both. |
| `clickhouse/clickhouse-server:26.9.7.9@sha256:1f9c29a7…` ([compose](extensions/pg-clickhouse-lab/docker-compose.yml)) | ClickHouse 26.9.7.9 | Latest ClickHouse release on Docker Hub (2026-09-30). pg_clickhouse 0.11 maps `cardinality` to `arrayFlattenedLength` only on 26.9+. |

Managed Postgres and ClickHouse Cloud versions are whatever the service runs. They are recorded in each lab's verification line, not pinned here.

The last Cloud run was 2026-10-02 in `ap-northeast-2`:

| Product | Versions |
|---|---|
| Managed Postgres | PostgreSQL 18.6. Extensions: pgvector 0.8.6; pg_clickhouse 0.10 available, 0.3 installed; pg_stat_ch 0.3 |
| ClickHouse Cloud | 26.6.1.2191 |

## Open work

Tracked as issues — [all open](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues) · [needs a re-run](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues?q=is%3Aopen+label%3Are-verify):

- [Re-verify postgis-fdw-bike on pg_clickhouse 0.10+](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/11)
- [provisioning: run the create/delete scripts against the live API](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/15)
- [postgis-fdw-bike: script and doc defects found while reading](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/12)
- [vector-search: claims that disagree with the scripts or each other](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/13)
