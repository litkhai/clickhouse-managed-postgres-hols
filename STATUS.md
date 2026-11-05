# STATUS.md

**As of 2026-11-05** — pg-clickhouse-lab gains reverse-ETL steps 05–09 with pg_cron 1.6.8 (#40); 00–09 re-run end to end on the new image. As of 2026-10-14 — postgis-fdw-bike and provisioning re-run end to end on a new Managed Postgres service (#11, #15). As of 2026-10-03: `docs/labs.json` added (notes-site export). As of 2026-10-02: split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

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
| `postgresql-18-cron=1.6.8-1.pgdg13+2` ([Dockerfile](extensions/pg-clickhouse-lab/postgres/Dockerfile)) | pg_cron 1.6.8 | Added on top of the pg_clickhouse image above for steps 05–09 (#40). Newest in the PGDG `trixie-pgdg` repository on 2026-11-05 (`apt-cache madison` inside the image); pg_cron v1.6.8 is the latest release (2026-09-08). PGDG drops old builds over time, so a rebuild may need a new pin and a re-run. |
| `clickhouse/clickhouse-server:26.9.7.9@sha256:1f9c29a7…` ([compose](extensions/pg-clickhouse-lab/docker-compose.yml)) | ClickHouse 26.9.7.9 | Latest ClickHouse release on Docker Hub (2026-09-30). pg_clickhouse 0.11 maps `cardinality` to `arrayFlattenedLength` only on 26.9+. |

Managed Postgres and ClickHouse Cloud versions are whatever the service runs. They are recorded in each lab's verification line, not pinned here.

The last Cloud runs, all in `ap-northeast-2`:

| Date | Labs | Managed Postgres | ClickHouse Cloud |
|---|---|---|---|
| 2026-10-14 | provisioning, postgis-fdw-bike | PostgreSQL 18.6, new `r6gd.medium`. PostGIS 3.6.4, pg_clickhouse 0.10, pg_cron 1.6, pg_stat_ch 0.4 | 26.6.1.2326 |
| 2026-10-02 | vector-search, provisioning (connect only) | PostgreSQL 18.6. pgvector 0.8.6; pg_clickhouse 0.10 available, 0.3 installed; pg_stat_ch 0.3 | 26.6.1.2191 |

## Open work

Tracked as issues — [all open](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues) · [needs a re-run](https://github.com/litkhai/clickhouse-managed-postgres-hols/issues?q=is%3Aopen+label%3Are-verify):


None open.
