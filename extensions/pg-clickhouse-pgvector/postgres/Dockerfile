# pg_clickhouse 0.11.1 on PostgreSQL 18, plus pgvector.
# The base is pinned to its multi-arch index digest (docker buildx imagetools inspect, 2026-11-20).
# pgvector comes from the PGDG apt repository that the postgres base image already configures
# (apt-cache madison postgresql-18-pgvector inside the image, 2026-11-20: 0.8.7-1.pgdg13+2 is the newest).
FROM ghcr.io/clickhouse/pg_clickhouse:18-0.11.1@sha256:cf501efa85484798da26b9d330d6e2f38e2462165cd338ddf89a64fb9adff743

ARG PGVECTOR_DEB=0.8.7-1.pgdg13+2

RUN apt-get update \
 && apt-get install -y --no-install-recommends "postgresql-${PG_MAJOR}-pgvector=${PGVECTOR_DEB}" \
 && rm -rf /var/lib/apt/lists/*
