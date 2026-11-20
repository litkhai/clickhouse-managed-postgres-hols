#!/bin/bash
# Open an interactive psql session against the lab PostgreSQL
exec docker exec -it pgvec-postgres psql -U postgres "$@"
