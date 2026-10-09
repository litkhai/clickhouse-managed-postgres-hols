#!/usr/bin/env bash
# Answer "did that actually run on ClickHouse, or did Postgres drag every row
# back and count them itself?"
#
#   ./scripts/explain-pushdown.sh                      # check the whole 20- file
#   ./scripts/explain-pushdown.sh -c 'SELECT ...'      # check one query
#   ./scripts/explain-pushdown.sh --target bike        # force the local tables
#
# --target is the schema the queries run against. The default is `ch` (the
# foreign tables from sql/40-fdw-clickhouse.sql) when it has any, else `bike`.
#
# EXPLAIN (VERBOSE) on a foreign table prints the SQL the wrapper intends to
# send. That text is the answer:
#
#   Foreign Scan
#     Remote SQL: SELECT a, count(*) FROM t GROUP BY a   <- pushed down
#
#   Aggregate
#     -> Foreign Scan
#          Remote SQL: SELECT a FROM t                   <- NOT pushed down
#
# The second form means every row crosses the network and Postgres aggregates
# locally, which is slower than never having moved the table. The wrapper does
# not warn about this; it just quietly does it.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$LAB_DIR"

TARGET=""
QUERY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target)  TARGET="${2:?--target needs a schema name}"; shift 2;;
        -c)        QUERY="${2:?-c needs a query}"; shift 2;;
        -h|--help) sed -n '2,24p' "$0"; exit 0;;
        *) echo "unknown option: $1" >&2; exit 2;;
    esac
done

# The name goes straight into SET search_path, so it has to be a plain identifier.
if [ -n "$TARGET" ] && ! [[ "$TARGET" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "--target must be a plain lower-case schema name, got: $TARGET" >&2
    exit 2
fi

foreign_tables_in() {
    psql_c -tA -c "SELECT count(*) FROM information_schema.foreign_tables
                   WHERE foreign_table_schema = '$1'"
}

if [ -z "$TARGET" ]; then
    if [ "$(foreign_tables_in ch)" -gt 0 ]; then TARGET=ch; else TARGET=bike; fi
fi
FT=$(foreign_tables_in "$TARGET")
echo "target schema: $TARGET ($FT foreign tables)"

if [ "${FT:-0}" -eq 0 ]; then
    cat >&2 <<MSG
No foreign tables in schema "$TARGET", so there is nothing to push down — the
queries are running against local tables.

Once the foreign server is imported (sql/40-fdw-clickhouse.sql), run this again
and it picks the foreign schema, or name it with --target. Until then the
EXPLAIN below only shows local plans.
MSG
fi

# One session per query: psql_c starts a fresh container each time, so a
# search_path set in one call is gone in the next. Both statements go in the
# same call. stdin is closed so docker cannot swallow the query list the loop
# below is reading from.
run_explain() {
    psql_c -c "SET search_path TO $TARGET, public" \
           -c "EXPLAIN (VERBOSE, COSTS OFF) $1" </dev/null 2>&1
}

verdict() {
    local plan="$1"
    if grep -q '^ERROR\|^psql: error' <<<"$plan"; then
        echo "ERROR         — EXPLAIN failed: $(grep -m1 '^ERROR\|^psql: error' <<<"$plan" | cut -c1-100)"
    elif grep -qi 'Remote SQL' <<<"$plan"; then
        if grep -i 'Remote SQL' <<<"$plan" | grep -qi 'GROUP BY\|count(\|sum(\|avg('; then
            echo "PUSHED DOWN   — the remote SQL carries the aggregation"
        else
            echo "NOT PUSHED    — remote SQL selects columns; Postgres aggregates them here"
        fi
    else
        echo "LOCAL         — no foreign table in this plan"
    fi
}

# A failed EXPLAIN must not end the script: psql's exit status is non-zero, and
# under `set -e` the assignment would exit before the error text was ever shown.
# The error is the verdict, and it is counted so the exit status can say so.
if [ -n "$QUERY" ]; then
    plan=$(run_explain "$QUERY") || true
    echo "$plan"
    echo
    v=$(verdict "$plan")
    echo "  verdict: $v"
    case "$v" in ERROR*) exit 1;; esac
    exit 0
fi

# One query per line. Split on semicolons, drop psql meta-commands (indented
# ones too — \set and \if sit inside an \if block) and comments, then keep only
# what starts with SELECT or WITH. The SET search_path line and anything else
# is setup for psql, not a query, and EXPLAINing it is an error.
split_queries() {
    python3 - sql/20-aggregate-pushdown.sql <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r'^[ \t]*\\.*$', '', text, flags=re.M)        # \timing, \echo, \set, \if ...
text = re.sub(r'^[ \t]*--.*$', '', text, flags=re.M)        # comments
for chunk in text.split(';'):
    chunk = chunk.strip()
    if re.match(r'(select|with)\b', chunk, flags=re.I):
        print(chunk.replace('\n', ' '))
PY
}

n=0
failed=0
while IFS= read -r q; do
    n=$(( n + 1 ))
    printf '\n══ query %d ═══════════════════════════════════════\n' "$n"
    echo "${q:0:90}…"
    plan=$(run_explain "$q") || true
    v=$(verdict "$plan")
    echo "  $v"
    case "$v" in ERROR*) failed=$(( failed + 1 ));; esac
    grep -i 'Remote SQL' <<<"$plan" | sed 's/^ */  /' | cut -c1-120 || true
done < <(split_queries)

[ "$n" -gt 0 ] || { echo "no queries found in sql/20-aggregate-pushdown.sql" >&2; exit 1; }
printf '\n%d queries checked, %d failed\n' "$n" "$failed"
[ "$failed" -eq 0 ]
