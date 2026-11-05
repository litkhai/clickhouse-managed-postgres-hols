# pg_clickhouse 0.11.0 on PostgreSQL 18 (the image step 00 always used), plus pg_cron for steps 05-09.
# The base is pinned to its multi-arch index digest (docker buildx imagetools inspect, 2026-10-01).
# pg_cron comes from the PGDG apt repository that the postgres base image already configures
# (apt-cache madison postgresql-18-cron inside the image, 2026-11-05: 1.6.8-1.pgdg13+2 is the newest).
FROM ghcr.io/clickhouse/pg_clickhouse:18-0.11.0@sha256:ce7a2b4bc7ee899fc1b87c82c87435acc8ede0903b138c66a580ccd197f88b29

ARG PG_CRON_DEB=1.6.8-1.pgdg13+2

RUN apt-get update \
 && apt-get install -y --no-install-recommends "postgresql-${PG_MAJOR}-cron=${PG_CRON_DEB}" \
 && rm -rf /var/lib/apt/lists/*
