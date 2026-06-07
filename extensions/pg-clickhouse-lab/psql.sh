#!/bin/bash
# Open an interactive psql session against the lab PostgreSQL
exec docker exec -it pgch-postgres psql -U postgres "$@"
