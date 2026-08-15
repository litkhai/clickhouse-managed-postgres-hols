#!/usr/bin/env bash
# Answer "did that actually run on ClickHouse, or did Postgres drag every row
# back and count them itself?"
#
#   ./scripts/explain-pushdown.sh                      # check the whole 20- file
#   ./scripts/explain-pushdown.sh -c 'SELECT ...'      # check one query
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

FT=$(psql_c -tA -c "SELECT count(*) FROM information_schema.foreign_tables")
if [ "${FT:-0}" -eq 0 ]; then
    cat >&2 <<'MSG'
No foreign tables exist yet, so there is nothing to push down — the queries in
sql/20-aggregate-pushdown.sql are running against the local table.

Once the foreign server is imported, point them at the foreign schema and run
this again. Until then the EXPLAIN below only shows local plans.
MSG
fi

run_explain() {
    psql_c -c "EXPLAIN (VERBOSE, COSTS OFF) $1" 2>&1
}

verdict() {
    local plan="$1"
    if grep -qi 'Remote SQL' <<<"$plan"; then
        if grep -i 'Remote SQL' <<<"$plan" | grep -qi 'GROUP BY\|count(\|sum(\|avg('; then
            echo "PUSHED DOWN   — the remote SQL carries the aggregation"
        else
            echo "NOT PUSHED    — remote SQL selects columns; Postgres aggregates them here"
        fi
    else
        echo "LOCAL         — no foreign table in this plan"
    fi
}

if [ "${1:-}" = "-c" ]; then
    plan=$(run_explain "$2")
    echo "$plan"
    echo
    echo "  verdict: $(verdict "$plan")"
    exit 0
fi

# Split the query file on semicolons at end of line, skipping psql meta-commands.
python3 - sql/20-aggregate-pushdown.sql > /tmp/bike-queries.txt <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r'^\\.*$', '', text, flags=re.M)          # \timing, \echo
text = re.sub(r'^\s*--.*$', '', text, flags=re.M)        # comments
for chunk in text.split(';'):
    chunk = chunk.strip()
    if chunk:
        print(chunk.replace('\n', ' '))
PY

n=0
while IFS= read -r q; do
    n=$(( n + 1 ))
    printf '\n══ query %d ═══════════════════════════════════════\n' "$n"
    echo "${q:0:90}…"
    plan=$(run_explain "$q")
    echo "  $(verdict "$plan")"
    grep -i 'Remote SQL' <<<"$plan" | sed 's/^ */  /' | cut -c1-120 || true
done < /tmp/bike-queries.txt
rm -f /tmp/bike-queries.txt
