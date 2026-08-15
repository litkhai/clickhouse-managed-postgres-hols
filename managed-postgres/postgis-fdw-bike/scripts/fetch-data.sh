#!/usr/bin/env bash
# Download Seoul public bike open data into data/.
#
#   ./scripts/fetch-data.sh                # stations + one month of trips
#   ./scripts/fetch-data.sh 2602 2603      # stations + those months
#
# Source: 서울 열린데이터광장, 공공누리 제1유형 (attribution, commercial use and
# modification allowed). No API key and no account are needed — the portal
# serves these over a plain POST.
#
#   OA-13252  공공자전거 대여소 정보    station master, with lat/lon
#   OA-15182  공공자전거 대여이력 정보  trip history, one row per trip
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
DATA_DIR="data"
ENDPOINT="https://datafile.seoul.go.kr/bigfile/iot/inf/nio_download.do?&useCache=false"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126 Safari/537.36'

# Monthly trip files, by the portal's own sequence number. The portal exposes no
# lookup for these, so they are pinned here. A case statement rather than an
# associative array: macOS still ships bash 3.2, which has no `declare -A`.
KNOWN_MONTHS="2601 2602 2603 2604 2605 2606"
trip_seq() {
    case "$1" in
        2601) echo 144;; 2602) echo 145;; 2603) echo 147;;
        2604) echo 148;; 2605) echo 149;; 2606) echo 150;;
        *)    echo "";;
    esac
}
STATION_SEQ=24          # 공공자전거 대여소 정보(26.6월 기준).xlsx

mkdir -p "$DATA_DIR"

# The portal returns 200 with an HTML alert when the parameters do not line up,
# and — worse — happily serves a *different* dataset's file when infSeq is wrong.
# So check what actually arrived rather than trusting the status code.
download() {
    local info_id="$1" seq="$2" inf_seq="$3" out="$4" expect="$5"
    local headers="$DATA_DIR/.headers"

    echo "  fetching $(basename "$out") …"
    curl -sS --fail --max-time 900 -A "$UA" -D "$headers" -o "$out" \
        -X POST "$ENDPOINT" \
        --data "infId=${info_id}&seqNo=&seq=${seq}&infSeq=${inf_seq}"

    local served
    served=$(sed -n 's/.*filename="\([^"]*\)".*/\1/p' "$headers" | tr -d '\r' \
             | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))')
    rm -f "$headers"

    if [ "$(head -c 15 "$out")" = "<html><head><sc" ]; then
        rm -f "$out"
        echo "    the portal rejected the request — seq/infSeq for $info_id have moved" >&2
        return 1
    fi
    case "$served" in
        *"$expect"*) ;;
        *) rm -f "$out"
           echo "    served \"$served\", which is not $expect — refusing it" >&2
           return 1;;
    esac
    echo "    $served  ($(du -h "$out" | cut -f1))"
}

# --- stations -------------------------------------------------------------
if [ -s "$DATA_DIR/stations.xlsx" ]; then
    echo "  data/stations.xlsx already present"
else
    download OA-13252 "$STATION_SEQ" 2 "$DATA_DIR/stations.xlsx" "대여소 정보"
fi

# --- trips ----------------------------------------------------------------
MONTHS=("$@")
[ ${#MONTHS[@]} -gt 0 ] || MONTHS=(2601)

for m in "${MONTHS[@]}"; do
    seq="$(trip_seq "$m")"
    [ -n "$seq" ] || {
        echo "no sequence number known for $m; known months: $KNOWN_MONTHS" >&2
        exit 1
    }
    out="$DATA_DIR/trips_${m}.csv"
    if [ -s "$out" ]; then
        echo "  $(basename "$out") already present ($(du -h "$out" | cut -f1))"
        continue
    fi
    download OA-15182 "$seq" 1 "$out" "대여이력 정보_${m}"
done

echo
echo "in $DATA_DIR/:"
ls -lh "$DATA_DIR" | tail -n +2 | awk '{printf "  %-28s %s\n", $9, $5}'
echo
echo "The CSVs are CP949, not UTF-8. load-trips.sh converts as it streams."
