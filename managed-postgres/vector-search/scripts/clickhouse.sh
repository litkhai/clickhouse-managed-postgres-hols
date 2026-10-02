#!/usr/bin/env bash
# clickhouse-client against your ClickHouse Cloud service, in a container.
#
#   ./scripts/clickhouse.sh -q 'SELECT version()'
#   ./scripts/clickhouse.sh < clickhouse/01-load-dbpedia.sql
#   ./scripts/clickhouse.sh < clickhouse/02-compare.sql
#
# Reads CH_HOST, CH_PORT, CH_USER and CH_PASSWORD from the environment, and for
# any that are not set there, from config.env. CH_PORT defaults to 9440 (TLS
# native port); CH_USER to default. CH_SECURE=0 turns TLS off, for a local
# server (then CH_PORT defaults to 9000).
#
# Statements are read from stdin as a multiquery script, so a whole .sql file
# runs in one go. With no arguments and a terminal on stdin you get an
# interactive session instead.
#
# The password never goes on a command line, where `ps` would show it: it
# reaches clickhouse-client as CLICKHOUSE_PASSWORD in the container's
# environment (docker run -e CLICKHOUSE_PASSWORD, no value). Output is masked so
# the hostname does not end up in a screenshot.
#
# The image is the pin extensions/pg-clickhouse-lab uses. Override with CH_IMAGE.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CH_IMAGE="${CH_IMAGE:-clickhouse/clickhouse-server:26.9.7.9@sha256:1f9c29a753cc07f9e2272a9d9383a840b222bbda78166da39dd10eecafe6500d}"

require_docker

# Environment first. Whatever is still unset is read from config.env, one name
# at a time in a subshell, so nothing else in that file leaks into this shell.
if [ -f "$LAB_DIR/config.env" ]; then
    for v in CH_HOST CH_PORT CH_USER CH_PASSWORD CH_SECURE; do
        if [ -z "${!v+set}" ]; then
            if val=$(set +u; . "$LAB_DIR/config.env" >/dev/null 2>&1 || true
                     [ -n "${!v+set}" ] || exit 1
                     printf '%s' "${!v}"); then
                export "$v=$val"
            fi
        fi
    done
fi

: "${CH_HOST:?set CH_HOST in config.env (or the environment)}"
CH_USER="${CH_USER:-default}"
if [ "${CH_SECURE:-1}" = "0" ]; then
    secure=(); default_port=9000
else
    secure=(--secure); default_port=9440
fi
CH_PORT="${CH_PORT:-$default_port}"

# clickhouse-client takes the password from CLICKHOUSE_PASSWORD (an empty value
# is a valid empty password).
export CLICKHOUSE_PASSWORD="${CH_PASSWORD:-}"

conn=(--host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER" ${secure[@]+"${secure[@]}"})

if [ $# -eq 0 ] && [ -t 0 ]; then
    docker run --rm -it -e CLICKHOUSE_PASSWORD "$CH_IMAGE" clickhouse-client "${conn[@]}"
else
    docker run --rm -i -e CLICKHOUSE_PASSWORD "$CH_IMAGE" \
        clickhouse-client "${conn[@]}" --multiquery "$@" 2>&1 | mask
fi
