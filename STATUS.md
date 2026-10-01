# STATUS.md

**As of 2026-10-01** — split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## CI

`checks` (on pull requests): `links`, `syntax`, `secrets` (gitleaks), `hygiene` — green.
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

## Open work

Tracked as issues — [all open](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues) · [needs a re-run](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues?q=is%3Aopen+label%3Are-verify):

- [Re-run the labs from their new paths](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/1) — `extensions/pg-clickhouse-lab` is done; `provisioning` and `vector-search` are next
- [Re-verify postgis-fdw-bike on pg_clickhouse 0.10+](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/11)
- [postgis-fdw-bike: script and doc defects found while reading](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/12)
- [vector-search: claims that disagree with the scripts or each other](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues/13)
