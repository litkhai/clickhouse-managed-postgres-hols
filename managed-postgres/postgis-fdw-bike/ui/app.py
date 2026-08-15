#!/usr/bin/env python3
"""A dashboard that shows which half of the system answered, and proves it.

Three kinds of endpoint, matching the three things the page has to do:

  /api/dashboard/*   The overview. A cheap pulse that can be polled, and a
                     costlier set of series that is only computed on request.
  /api/map/<name>    PostGIS. Geometry, so it cannot leave Postgres.
  /api/agg/<name>    Aggregates. The shape that pushes down to ClickHouse.
  /api/pushdown/*    Whether that actually happened, read out of the plan.

Every response carries the SQL that ran, how long it took, and — for the
aggregates — a verdict taken from the plan tree: whether the work was sent to
ClickHouse or whether the rows were quietly dragged back here to be counted.
That verdict is the point of the page. A dashboard that only shows numbers
cannot tell you where they came from, and "it's fast" is not evidence that
anything was pushed down.

Standard library only apart from psycopg, so the image stays small and there is
no build step to explain.
"""
import collections
import datetime as dt
import itertools
import json
import os
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import psycopg
from psycopg import ClientCursor

HERE = Path(__file__).parent
PORT = int(os.environ.get("UI_PORT", "8080"))

# Seoul is UTC+9 all year — no daylight saving — so the whole timezone story is
# this one constant. The table stores UTC (see sql/01-schema.sql); every date
# and hour the page shows or filters on is Korean local time, converted here.
KST = "interval '9 hours'"

# Which schema the Statistics tab reads. Point it at the foreign schema and the
# same SQL runs on ClickHouse; the verdict will say so.
LOCAL_SCHEMA = os.environ.get("LOCAL_SCHEMA", "bike")
AGG_SCHEMA = os.environ.get("AGG_SCHEMA", LOCAL_SCHEMA)

# Where the foreign tables are imported, for the side-by-side on the Pushdown
# tab. Empty until someone has run IMPORT FOREIGN SCHEMA; the page reports that
# rather than pretending the comparison is available.
FOREIGN_SCHEMA = os.environ.get("FOREIGN_SCHEMA", "")

# A full scan of 24M rows takes tens of seconds while the data still lives in
# Postgres. Without a ceiling, a few impatient clicks queue several of them at
# once; they evict each other from a shared_buffers smaller than the table and
# every one gets slower. Better to fail a query than to let the pile grow.
STATEMENT_TIMEOUT_MS = int(os.environ.get("STATEMENT_TIMEOUT_MS", "120000"))

# One heavy query at a time. Aborting a fetch in the browser only closes the
# connection — the server keeps executing, verified by watching pg_stat_activity
# after a client hung up. So the pile-up has to be prevented here: several
# concurrent scans of a table larger than shared_buffers evict each other and
# every one of them gets slower than if it had run alone. Measured: the same
# query took 18s alone and 49s with two others in flight.
QUERY_SLOT = threading.Semaphore(1)

# Every query the page runs is recorded here with the verdict from its plan.
# Kept in memory on purpose: this is a demo aid, not an audit trail, and a ring
# buffer means it cannot grow without bound during a long session.
LOG = collections.deque(maxlen=300)
LOG_LOCK = threading.Lock()


SEQ = itertools.count(1)


def record(kind, name, verdict, ms, rows, sql, nodes=None, describe="", schema=""):
    """One line per query, with everything needed to argue about it afterwards.

    The Log tab is the only place the whole session is visible at once, so an
    entry has to stand on its own: not just how long it took, but which slice
    was asked for, which schema answered, how wide the plan got and how much
    came back over the wire. A duration without those is unfalsifiable.
    """
    with LOG_LOCK:
        LOG.appendleft({
            "n": next(SEQ),
            "at": dt.datetime.now().strftime("%H:%M:%S"),
            "kind": kind, "name": name, "schema": schema, "describe": describe,
            "where": verdict["where"], "verdict": verdict.get("verdict", ""),
            "detail": verdict["detail"],
            "crossed": verdict.get("rows_crossed"),
            "crossed_measured": verdict.get("rows_crossed_measured", False),
            "widest": verdict.get("rows_widest"),
            "remote_sql": verdict.get("remote_sql", ""),
            "ms": ms, "rows": rows, "sql": sql, "nodes": nodes or [],
        })


def dsn():
    return (f"host={os.environ['PGHOST']} port={os.environ.get('PGPORT', '5432')} "
            f"user={os.environ.get('PGUSER', 'postgres')} password={os.environ['PGPASSWORD']} "
            f"dbname={os.environ.get('PGDATABASE', 'postgres')} "
            f"sslmode={os.environ.get('PGSSLMODE', 'require')} "
            f"options='-c statement_timeout={STATEMENT_TIMEOUT_MS}'")


def connect():
    """A client-side-binding cursor, chosen deliberately.

    Two reasons, and the second is the one that matters here. First, the SQL the
    page displays is then the exact text that ran, rather than a template with
    $1 in it. Second, a parameterised query reaches a foreign table as a generic
    plan with placeholders, and a wrapper that cannot see the constants has less
    to push down — literals give it the WHERE clause it needs. Binding on the
    client keeps the demo honest about both.
    """
    return psycopg.connect(dsn(), cursor_factory=ClientCursor)


# --------------------------------------------------------------------------- #
# Filters. One object, parsed from the query string, applied to every query on
# the page so that what the dashboard shows and what the aggregates count are
# always the same slice.
# --------------------------------------------------------------------------- #

BUCKETS = {"hour": "1 hour", "day": "24 hours", "week": "1 week",
           "month": "1 month", "quarter": "1 quarter"}


class Filters:
    """A KST-facing filter over a UTC column.

    Dates are Korean calendar days because that is what a reader of this data
    means by "the 3rd"; the column is UTC. A KST day D is the UTC half-open
    range [D 00:00 - 9h, D+1 00:00 - 9h), and doing that conversion in one place
    is the only way the numbers stay explicable.
    """

    def __init__(self, q):
        g = lambda k, d="": (q.get(k, [d])[0] or "").strip()   # noqa: E731
        self.date_from = g("from")
        self.date_to = g("to")
        self.districts = [d for d in g("districts").split(",") if d]
        self.hour_from = int(g("hour_from", "0") or 0)
        self.hour_to = int(g("hour_to", "23") or 23)
        self.daytype = g("daytype", "all") or "all"
        self.min_trips = int(g("min_trips", "0") or 0)
        self.limit = min(int(g("limit", "15") or 15), 200)
        # Whitelisted, not bound: date_trunc's first argument has to reach the
        # wrapper as a literal for the rollup to be pushed down, and a value
        # that ends up inside SQL as a literal is only safe if it can only ever
        # be one of these five.
        self.bucket = g("bucket", "day") if g("bucket", "day") in BUCKETS else "day"

    # -- predicates ------------------------------------------------------- #

    def where(self, t="t", s=None, params=None):
        """Predicates on the trips alias `t`, optionally the stations alias `s`.

        Returns SQL with %s placeholders and appends the values to `params`, so
        the caller binds them once through the client cursor.
        """
        parts, params = [], params if params is not None else []
        if self.date_from:
            parts.append(f"{t}.started_at >= %s::date - {KST}")
            params.append(self.date_from)
        if self.date_to:
            # +1 day, so "to" is inclusive of the whole Korean day.
            parts.append(f"{t}.started_at < %s::date + interval '1 day' - {KST}")
            params.append(self.date_to)
        if not (self.hour_from == 0 and self.hour_to == 23):
            parts.append(
                f"extract(hour FROM {t}.started_at + {KST})::int BETWEEN %s AND %s")
            params += [self.hour_from, self.hour_to]
        if self.daytype == "weekend":
            parts.append(f"extract(dow FROM {t}.started_at + {KST})::int IN (0, 6)")
        elif self.daytype == "weekday":
            parts.append(f"extract(dow FROM {t}.started_at + {KST})::int BETWEEN 1 AND 5")
        if self.districts and s:
            parts.append(f"{s}.district = ANY(%s)")
            params.append(self.districts)
        return (" AND ".join(parts) or "true"), params

    def having(self, params=None):
        params = params if params is not None else []
        if self.min_trips > 0:
            params.append(self.min_trips)
            return "HAVING count(*) >= %s", params
        return "", params

    def describe(self):
        """The filter as parts, for the page to word in whichever language.

        Returning a finished English sentence here was fine while the UI was
        English; it is not once the same string has to read naturally in Korean,
        where the order and the particles differ.
        """
        return {
            "from": self.date_from, "to": self.date_to,
            "districts": self.districts,
            "hours": None if (self.hour_from == 0 and self.hour_to == 23)
                     else [self.hour_from, self.hour_to],
            "daytype": None if self.daytype == "all" else self.daytype,
            "min_trips": self.min_trips or None,
            "bucket": self.bucket,
        }

    def as_dict(self):
        return {"from": self.date_from, "to": self.date_to,
                "districts": self.districts, "hour_from": self.hour_from,
                "hour_to": self.hour_to, "daytype": self.daytype,
                "min_trips": self.min_trips, "limit": self.limit,
                "bucket": self.bucket}


# --------------------------------------------------------------------------- #
# The plan tree. Reading it is the only honest answer to "did this push down?",
# and reading it properly means walking the JSON rather than grepping the text.
# --------------------------------------------------------------------------- #

AGG_NODES = ("Aggregate", "GroupAggregate", "HashAggregate", "WindowAgg")
# Node types that mean real per-row work happened on this side of the wire.
LOCAL_WORK = AGG_NODES + ("Sort", "Incremental Sort", "Hash Join", "Merge Join",
                          "Nested Loop", "Group", "Unique")


def flatten(node, depth=0, out=None):
    out = [] if out is None else out
    entry = {
        "depth": depth,
        "type": node.get("Node Type", "?"),
        "relation": node.get("Relation Name") or node.get("Alias") or "",
        "schema": node.get("Schema") or "",
        "remote_sql": node.get("Remote SQL") or "",
        "plan_rows": node.get("Plan Rows"),
        "actual_rows": node.get("Actual Rows"),
        "ms": node.get("Actual Total Time"),
    }
    entry["remote"] = entry["type"] == "Foreign Scan"
    out.append(entry)
    for child in node.get("Plans", []) or []:
        flatten(child, depth + 1, out)
    return out


def analyse(plan_json, fdw_ready):
    """Turn one EXPLAIN (FORMAT JSON) into a verdict plus an annotated tree.

    The distinction the old text-matching version could not make: a plan with no
    foreign scan at all is not "failed to push down", it is "there is nothing to
    push down to". Those two look identical if you only check whether the string
    "Remote SQL" is present, and telling a reader their query fell back when no
    FDW was ever configured is worse than saying nothing.
    """
    root = plan_json[0]["Plan"]
    nodes = flatten(root)
    measured = any(n["actual_rows"] is not None for n in nodes)
    foreign = [n for n in nodes if n["remote"]]

    def rows_of(n):
        return n["actual_rows"] if n["actual_rows"] is not None else n["plan_rows"]

    # The widest point of the plan — how many rows this side had to put through
    # a join, a sort or an aggregate. Against the row count that crossed the
    # wire it is the whole argument: 3.4M sorted here, or 15 rows fetched.
    widest = max((rows_of(n) or 0) for n in nodes) if nodes else 0

    if not foreign:
        code = "local" if fdw_ready else "no_fdw"
        detail = ("no foreign table in this plan — it read local Postgres tables"
                  if fdw_ready else
                  "no foreign tables are configured, so there is nothing to push down")
        return {"where": "postgres", "verdict": code, "detail": detail,
                "rows_crossed": None, "rows_crossed_measured": measured,
                "rows_widest": widest, "remote_sql": "", "nodes": nodes}

    crossed = sum(rows_of(n) or 0 for n in foreign)
    remote_sql = "\n\n".join(n["remote_sql"] for n in foreign if n["remote_sql"])
    remote_aggregates = "group by" in remote_sql.lower() or any(
        f in remote_sql.lower() for f in ("count(", "sum(", "avg(", "min(", "max("))

    # Work above the foreign scans, in the parts of the tree that are local.
    depth_of_shallowest_foreign = min(n["depth"] for n in foreign)
    local_above = [n["type"] for n in nodes
                   if n["depth"] < depth_of_shallowest_foreign and n["type"] in LOCAL_WORK]

    if remote_aggregates and not any(t in AGG_NODES for t in local_above):
        return {"where": "clickhouse", "verdict": "pushed",
                "detail": "the remote SQL carries the aggregation — ClickHouse did the counting",
                "rows_crossed": crossed, "rows_crossed_measured": measured,
                "rows_widest": widest, "remote_sql": remote_sql, "nodes": nodes}
    if remote_aggregates:
        return {"where": "mixed", "verdict": "partial",
                "detail": f"aggregated remotely, then re-aggregated here ({', '.join(local_above)})",
                "rows_crossed": crossed, "rows_crossed_measured": measured,
                "rows_widest": widest, "remote_sql": remote_sql, "nodes": nodes}
    return {"where": "postgres", "verdict": "dragged",
            "detail": "the foreign scan selects columns only — every row crossed the "
                      "network to be counted here",
            "rows_crossed": crossed, "rows_crossed_measured": measured,
            "rows_widest": widest, "remote_sql": remote_sql, "nodes": nodes}


def explain(cur, sql, analyze=False):
    """The plan for `sql`, as JSON.

    Without ANALYZE this costs nothing and the row counts are the planner's
    guesses. With it the query runs a second time and the counts are what
    actually happened — which is the number that settles an argument about how
    much crossed the wire, and why the page makes it an explicit choice rather
    than paying for it on every click.
    """
    # COSTS stays on even though no cost is ever displayed: turning it off also
    # removes "Plan Rows", and the estimated width of the foreign scan is the
    # whole point of the unmeasured view — 25 rows coming back versus 24 million
    # is the difference this page exists to show.
    opts = "VERBOSE, FORMAT JSON"
    if analyze:
        opts = "ANALYZE, VERBOSE, BUFFERS, FORMAT JSON"
    cur.execute(f"EXPLAIN ({opts}) " + sql)
    return cur.fetchone()[0]


def fdw_state(cur):
    cur.execute("""
        SELECT (SELECT count(*) FROM pg_extension WHERE extname = 'pg_clickhouse'),
               (SELECT count(*) FROM pg_foreign_server),
               (SELECT coalesce(string_agg(srvname, ', '), '') FROM pg_foreign_server),
               (SELECT count(*) FROM information_schema.foreign_tables),
               (SELECT coalesce(string_agg(DISTINCT foreign_table_schema, ', '), '')
                  FROM information_schema.foreign_tables)""")
    ext, servers, srvnames, ftables, fschemas = cur.fetchone()
    state = {"extension": bool(ext), "servers": servers, "server_names": srvnames,
             "foreign_tables": ftables, "foreign_schemas": fschemas,
             "local_schema": LOCAL_SCHEMA, "agg_schema": AGG_SCHEMA,
             "foreign_schema": FOREIGN_SCHEMA, "ready": bool(ftables)}
    # What the Statistics tab will actually read if nobody touches the toggle.
    # Reporting the environment variable instead was wrong the moment the tab
    # learned to prefer the remote side on its own.
    state["default_schema"] = pick_schema("auto", state)[0]
    return state


# --------------------------------------------------------------------------- #
# PostGIS: geometry, returned as GeoJSON. None of this can move.
# --------------------------------------------------------------------------- #

MAP_QUERIES = {
    "stations": {
        "label": "Stations",
        "note": "Points sized by departures in the filtered window. The join to "
                "the trip count is by integer id — geometry never leaves Postgres.",
        "sql": """
WITH demand AS (
    SELECT t.start_station_id AS station_id, count(*) AS departures
    FROM {L}.trips t JOIN {L}.stations s ON s.station_id = t.start_station_id
    WHERE {where}
    GROUP BY 1
)
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', coalesce(json_agg(json_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(s.geom)::json,
      'properties', json_build_object(
          'id', s.station_id, 'name', s.name, 'district', s.district,
          'racks', s.racks, 'departures', coalesce(d.departures, 0))
  )), '[]'::json))
FROM {L}.stations s JOIN demand d USING (station_id)"""},

    "voronoi": {
        "label": "Service areas",
        "note": "ST_VoronoiPolygons over every station, clipped to the network "
                "hull. There is no ClickHouse equivalent of this.",
        "sql": """
WITH cells AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(ST_Collect(geom)))).geom AS cell
    FROM {L}.stations
), hull AS (SELECT ST_ConvexHull(ST_Collect(geom)) AS h FROM {L}.stations),
demand AS (
    SELECT t.start_station_id AS station_id, count(*) AS departures
    FROM {L}.trips t JOIN {L}.stations s ON s.station_id = t.start_station_id
    WHERE {where}
    GROUP BY 1
)
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', coalesce(json_agg(json_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(ST_Intersection(c.cell, hull.h))::json,
      'properties', json_build_object(
          'name', s.name, 'district', s.district,
          'departures', coalesce(d.departures, 0),
          'km2', round((ST_Area(ST_Intersection(c.cell, hull.h)::geography)/1e6)::numeric, 3))
  )), '[]'::json))
FROM cells c CROSS JOIN hull
JOIN {L}.stations s ON ST_Within(s.geom, c.cell)
LEFT JOIN demand d ON d.station_id = s.station_id
WHERE ST_Area(ST_Intersection(c.cell, hull.h)::geography) > 0"""},

    "flows": {
        "label": "Flows",
        "note": "The heaviest origin–destination pairs drawn as lines. The "
                "counting can move; ST_MakeLine cannot.",
        "sql": """
WITH pairs AS (
    SELECT t.start_station_id, t.end_station_id, count(*) AS trips
    FROM {L}.trips t JOIN {L}.stations s ON s.station_id = t.start_station_id
    WHERE {where} AND t.start_station_id <> t.end_station_id
    GROUP BY 1, 2
    ORDER BY trips DESC LIMIT 400
)
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', coalesce(json_agg(json_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(ST_MakeLine(s.geom, e.geom))::json,
      'properties', json_build_object(
          'from', s.name, 'to', e.name, 'trips', p.trips,
          'crow_m', round(ST_Distance(s.geom::geography, e.geom::geography)),
          'from_lon', ST_X(s.geom), 'from_lat', ST_Y(s.geom),
          'to_lon', ST_X(e.geom), 'to_lat', ST_Y(e.geom))
  )), '[]'::json))
FROM pairs p
JOIN {L}.stations s ON s.station_id = p.start_station_id
JOIN {L}.stations e ON e.station_id = p.end_station_id"""},

    "pressure": {
        "label": "Rebalancing",
        "note": "Arrivals minus departures per station. Red drains and needs "
                "bikes brought in; blue fills up.",
        "sql": """
WITH moves AS (
    SELECT t.start_station_id AS station_id, count(*) AS out_t, 0::bigint AS in_t
    FROM {L}.trips t JOIN {L}.stations s ON s.station_id = t.start_station_id
    WHERE {where}
    GROUP BY 1
    UNION ALL
    SELECT t.end_station_id, 0::bigint, count(*)
    FROM {L}.trips t JOIN {L}.stations s ON s.station_id = t.start_station_id
    WHERE {where}
    GROUP BY 1
), net AS (
    SELECT station_id, sum(in_t) - sum(out_t) AS net, sum(in_t) + sum(out_t) AS total
    FROM moves WHERE station_id IS NOT NULL GROUP BY 1
)
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', coalesce(json_agg(json_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(s.geom)::json,
      'properties', json_build_object(
          'name', s.name, 'district', s.district,
          'net', n.net, 'total', n.total, 'racks', s.racks)
  )), '[]'::json))
FROM net n JOIN {L}.stations s USING (station_id)"""},
}

# The pressure map needs its filter twice, once per arm of the UNION.
MAP_WHERE_COUNT = {"pressure": 2}


# --------------------------------------------------------------------------- #
# Aggregates: the shape that travels. Written against a schema placeholder so
# the same text runs locally or against the foreign tables.
# --------------------------------------------------------------------------- #

AGG_QUERIES = {
    "character": {
        "label": "Commuter or leisure",
        "note": "Peak share against weekend share, per station. Two conditional "
                "sums and a count — nothing a column store cannot do.",
        "sql": """
SELECT s.district, s.name,
       count(*) AS trips,
       round(100.0 * sum(CASE WHEN extract(hour FROM t.started_at + {KST})::int
                                   IN (7, 8, 9, 18, 19, 20)
                              THEN 1 ELSE 0 END) / count(*), 1) AS peak_pct,
       round(100.0 * sum(CASE WHEN extract(dow FROM t.started_at + {KST})::int IN (0, 6)
                              THEN 1 ELSE 0 END) / count(*), 1) AS weekend_pct,
       round(avg(t.duration_min), 1) AS avg_min
FROM {S}.trips t JOIN {S}.stations s ON s.station_id = t.start_station_id
WHERE {where}
GROUP BY s.district, s.name
{having}
ORDER BY trips DESC LIMIT {limit}"""},

    "corridors": {
        "label": "Heaviest corridors",
        "note": "Origin–destination pairs. Joins two copies of stations to trips; "
                "all three are remote, so the whole join can move.",
        "sql": """
SELECT o.district || ' → ' || d.district AS route,
       o.name AS origin, d.name AS destination,
       count(*) AS trips,
       round(avg(t.duration_min), 1) AS avg_min,
       round(avg(t.distance_m)) AS avg_m
FROM {S}.trips t
JOIN {S}.stations o ON o.station_id = t.start_station_id
JOIN {S}.stations d ON d.station_id = t.end_station_id
WHERE {where} AND t.start_station_id <> t.end_station_id
GROUP BY 1, 2, 3
{having}
ORDER BY trips DESC LIMIT {limit}"""},

    "districts": {
        "label": "By district",
        "note": "Twenty-five groups out of millions of rows — the best possible "
                "case for pushing down, because almost nothing comes back.",
        "sql": """
SELECT s.district,
       count(DISTINCT s.station_id) AS stations,
       count(*) AS trips,
       round(avg(t.duration_min), 1) AS avg_min,
       round(avg(t.distance_m)) AS avg_m,
       round(100.0 * sum(CASE WHEN t.start_station_id = t.end_station_id
                              THEN 1 ELSE 0 END) / count(*), 1) AS round_trip_pct
FROM {S}.trips t JOIN {S}.stations s ON s.station_id = t.start_station_id
WHERE {where}
GROUP BY s.district
{having}
ORDER BY trips DESC LIMIT {limit}"""},

    "hourly": {
        "label": "Hour of day",
        "note": "Twenty-four groups. Reads every row in the window and returns "
                "one line per hour.",
        "sql": """
SELECT extract(hour FROM t.started_at + {KST})::int AS hour_kst,
       count(*) AS trips,
       round(avg(t.duration_min), 1) AS avg_min,
       sum(CASE WHEN extract(dow FROM t.started_at + {KST})::int IN (0, 6)
                THEN 1 ELSE 0 END) AS weekend,
       sum(CASE WHEN extract(dow FROM t.started_at + {KST})::int BETWEEN 1 AND 5
                THEN 1 ELSE 0 END) AS weekday
FROM {S}.trips t JOIN {S}.stations s ON s.station_id = t.start_station_id
WHERE {where}
GROUP BY 1 ORDER BY 1"""},

    "timeseries": {
        "label": "Over time",
        "note": "One row per bucket, and the bucket is yours to pick. Coarser "
                "buckets read exactly the same rows but return far fewer — which "
                "is the cheap half of a rollup, and the half a column store does "
                "without being asked.",
        "sql": """
SELECT date_trunc('{bucket}', t.started_at + {KST}) AS bucket_kst,
       count(*) AS trips,
       count(DISTINCT t.start_station_id) AS stations,
       round(avg(t.duration_min), 1) AS avg_min,
       round(avg(t.distance_m)) AS avg_m
FROM {S}.trips t JOIN {S}.stations s ON s.station_id = t.start_station_id
WHERE {where}
GROUP BY 1
{having}
ORDER BY 1 DESC LIMIT {limit}"""},
}


def pick_schema(side, state):
    """Which schema answers the Statistics tab.

    Kept a request parameter rather than an environment variable, because the
    interesting move is flipping between the two and watching the badge change.
    A restart to see the other half of the point is a bad demo.
    """
    remote_ok = bool(FOREIGN_SCHEMA and state["ready"])
    if side == "local":
        return LOCAL_SCHEMA, "local"
    if side == "foreign":
        return (FOREIGN_SCHEMA, "foreign") if remote_ok else (LOCAL_SCHEMA, "local")
    # auto: prefer the remote side when it exists, since that is the claim the
    # lab is making; fall back to whatever AGG_SCHEMA says when it does not.
    return (FOREIGN_SCHEMA, "foreign") if remote_ok else (AGG_SCHEMA, "local")


def build_agg(name, f, schema):
    """Render one aggregate against a schema, with the filters bound in."""
    q = AGG_QUERIES[name]
    params = []
    where, params = f.where("t", "s", params)
    having, params = f.having(params)
    sql = (q["sql"]
           .replace("{S}", schema)
           .replace("{KST}", KST)
           .replace("{where}", where)
           .replace("{having}", having)
           .replace("{bucket}", f.bucket)
           .replace("{limit}", str(f.limit)))
    return sql.strip(), params


def build_map(name, f):
    q = MAP_QUERIES[name]
    params = []
    sql = q["sql"].replace("{L}", LOCAL_SCHEMA).replace("{KST}", KST)
    for _ in range(MAP_WHERE_COUNT.get(name, 1)):
        where, params = f.where("t", "s", params)
        sql = sql.replace("{where}", where, 1)
    return sql.strip(), params


# --------------------------------------------------------------------------- #
# The dashboard. Split in two on purpose: what can be polled and what cannot.
# --------------------------------------------------------------------------- #

# Measured against the real service, 24M rows: count(*) 1.0s, min/max 15ms
# (index), one minute of history 18ms (index), count(DISTINCT date) 14.3s and a
# full daily rollup 5.1s. The first three can be asked for every fifteen
# seconds; the last two cannot, and an earlier version of this page polled the
# 14-second one on a timer. So the pulse below is only ever index work, and
# everything that scans lives behind the Run button with a short cache.
PULSE_SQL = f"""
SELECT (SELECT count(*) FROM {LOCAL_SCHEMA}.stations),
       (SELECT reltuples::bigint FROM pg_class WHERE oid = '{LOCAL_SCHEMA}.trips'::regclass),
       pg_size_pretty(pg_total_relation_size('{LOCAL_SCHEMA}.trips')),
       (SELECT to_char(min(started_at) + {KST}, 'YYYY-MM-DD') FROM {LOCAL_SCHEMA}.trips),
       (SELECT to_char(max(started_at) + {KST}, 'YYYY-MM-DD HH24:MI') FROM {LOCAL_SCHEMA}.trips),
       (SELECT extract(epoch FROM now()::timestamp - max(started_at))::int
          FROM {LOCAL_SCHEMA}.trips),
       (SELECT count(*) FROM {LOCAL_SCHEMA}.trips
         WHERE started_at > now()::timestamp - interval '60 minutes'),
       current_setting('server_version')"""

MINUTES_SQL = f"""
SELECT to_char(date_trunc('minute', started_at) + {KST}, 'HH24:MI') AS minute_kst,
       count(*) AS trips
FROM {LOCAL_SCHEMA}.trips
WHERE started_at > date_trunc('minute', now()::timestamp) - interval '60 minutes'
GROUP BY 1 ORDER BY 1"""

# The charts. Each is one round trip and each reports its own cost, because the
# interesting thing about this dashboard is not the shapes — it is that the
# cheap ones stay cheap and the expensive ones are exactly the ones that would
# benefit from running somewhere else.
SERIES = {
    "daily": {
        "label": "Trips per day",
        "sql": f"""
SELECT to_char((t.started_at + {KST})::date, 'YYYY-MM-DD') AS label,
       count(*) AS value
FROM {LOCAL_SCHEMA}.trips t JOIN {LOCAL_SCHEMA}.stations s
  ON s.station_id = t.start_station_id
WHERE {{where}}
GROUP BY 1 ORDER BY 1"""},

    "hourly": {
        "label": "Hour of day",
        "sql": f"""
SELECT lpad(extract(hour FROM t.started_at + {KST})::int::text, 2, '0') AS label,
       count(*) FILTER (WHERE extract(dow FROM t.started_at + {KST})::int BETWEEN 1 AND 5)
         AS weekday,
       count(*) FILTER (WHERE extract(dow FROM t.started_at + {KST})::int IN (0, 6))
         AS weekend
FROM {LOCAL_SCHEMA}.trips t JOIN {LOCAL_SCHEMA}.stations s
  ON s.station_id = t.start_station_id
WHERE {{where}}
GROUP BY 1 ORDER BY 1"""},

    "districts": {
        "label": "Busiest districts",
        "sql": f"""
SELECT s.district AS label, count(*) AS value
FROM {LOCAL_SCHEMA}.trips t JOIN {LOCAL_SCHEMA}.stations s
  ON s.station_id = t.start_station_id
WHERE {{where}}
GROUP BY 1 ORDER BY value DESC LIMIT 12"""},

    "duration": {
        "label": "Trip length",
        "sql": f"""
SELECT CASE width_bucket(t.duration_min, 0, 120, 8)
         WHEN 1 THEN '0–15'   WHEN 2 THEN '15–30'  WHEN 3 THEN '30–45'
         WHEN 4 THEN '45–60'  WHEN 5 THEN '60–75'  WHEN 6 THEN '75–90'
         WHEN 7 THEN '90–105' WHEN 8 THEN '105–120' ELSE '120+' END AS label,
       count(*) AS value
FROM {LOCAL_SCHEMA}.trips t JOIN {LOCAL_SCHEMA}.stations s
  ON s.station_id = t.start_station_id
WHERE {{where}}
GROUP BY 1, width_bucket(t.duration_min, 0, 120, 8)
ORDER BY width_bucket(t.duration_min, 0, 120, 8)"""},
}

# A short cache, so that switching tabs or a second reader does not pay for the
# same 20-second rollup twice. Keyed by the filter, because a different filter
# is a different question.
CACHE, CACHE_LOCK, CACHE_TTL = {}, threading.Lock(), 120.0


def cached(key, produce):
    now = time.monotonic()
    with CACHE_LOCK:
        hit = CACHE.get(key)
        if hit and now - hit[0] < CACHE_TTL:
            return dict(hit[1], cached=True)
    value = produce()
    with CACHE_LOCK:
        CACHE[key] = (now, value)
        if len(CACHE) > 40:                      # demo aid, not a real cache
            CACHE.pop(next(iter(CACHE)))
    return dict(value, cached=False)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path, q = parsed.path, urllib.parse.parse_qs(parsed.query)
        try:
            if path in ("/", "/index.html"):
                return self._send(200, (HERE / "index.html").read_bytes(),
                                  "text/html; charset=utf-8")
            if path == "/api/catalog":
                return self._catalog()
            if path == "/api/dashboard/pulse":
                return self._pulse()
            if path == "/api/dashboard/series":
                return self._series(Filters(q))
            if path == "/api/log":
                return self._log()
            if path == "/api/pushdown/state":
                with connect() as conn, conn.cursor() as cur:
                    return self._send(200, json.dumps(fdw_state(cur)))
            if path == "/api/pushdown/run":
                return self._pushdown(q)
            if path.startswith("/api/map/"):
                return self._map(path.rsplit("/", 1)[1], Filters(q))
            if path.startswith("/api/agg/"):
                return self._agg(path.rsplit("/", 1)[1], Filters(q),
                                 (q.get("side", ["auto"])[0] or "auto"))
            self._send(404, json.dumps({"error": "not found"}))
        except Exception as exc:                                  # noqa: BLE001
            self._send(500, json.dumps({"error": f"{type(exc).__name__}: {exc}"}))

    # -- catalog ---------------------------------------------------------- #

    def _catalog(self):
        with connect() as conn, conn.cursor() as cur:
            cur.execute(f"""
                SELECT coalesce(string_agg(DISTINCT district, ',' ORDER BY district), '')
                FROM {LOCAL_SCHEMA}.stations WHERE district IS NOT NULL""")
            districts = [d for d in cur.fetchone()[0].split(",") if d]
            # Default the range to the last four weeks of data rather than all
            # of it: the whole history is a 24M-row scan per chart, and a first
            # visit that takes a minute teaches the wrong lesson.
            cur.execute(f"""
                SELECT to_char(max(started_at) + {KST}, 'YYYY-MM-DD'),
                       to_char(max(started_at) + {KST} - interval '27 days', 'YYYY-MM-DD'),
                       to_char(min(started_at) + {KST}, 'YYYY-MM-DD')
                FROM {LOCAL_SCHEMA}.trips""")
            newest, default_from, oldest = cur.fetchone()
            state = fdw_state(cur)
        self._send(200, json.dumps({
            "maps": [{"key": k, "label": v["label"], "note": v["note"]}
                     for k, v in MAP_QUERIES.items()],
            "aggs": [{"key": k, "label": v["label"], "note": v["note"]}
                     for k, v in AGG_QUERIES.items()],
            "series": [{"key": k, "label": v["label"]} for k, v in SERIES.items()],
            "districts": districts,
            "bounds": {"oldest": oldest, "newest": newest},
            "defaults": {"from": default_from, "to": newest},
            "fdw": state,
        }))

    # -- dashboard -------------------------------------------------------- #

    def _pulse(self):
        t0 = time.perf_counter()
        with connect() as conn, conn.cursor() as cur:
            cur.execute(PULSE_SQL)
            (stations, approx_trips, size, first, last, behind, last_hour,
             pgver) = cur.fetchone()
            cur.execute(MINUTES_SQL)
            minutes = [{"label": r[0], "value": r[1]} for r in cur.fetchall()]

            cur.execute("""
                SELECT coalesce((SELECT state FROM pg_stat_replication LIMIT 1), 'not connected'),
                       coalesce((SELECT active::text FROM pg_replication_slots LIMIT 1), 'no slot'),
                       coalesce((SELECT pg_size_pretty(pg_wal_lsn_diff(
                            pg_current_wal_lsn(), confirmed_flush_lsn))
                          FROM pg_replication_slots LIMIT 1), '-'),
                       coalesce((SELECT string_agg(schemaname||'.'||tablename, ', ')
                          FROM pg_publication_tables), 'none')""")
            cdc_state, slot_active, unconsumed, published = cur.fetchone()

            try:
                cur.execute("""
                    SELECT coalesce((SELECT active::text FROM cron.job
                                     WHERE jobname = 'bike-generate'), 'not scheduled'),
                           coalesce((SELECT count(*) FROM cron.job_run_details
                                     WHERE status = 'succeeded')::text, '0'),
                           coalesce((SELECT to_char(max(start_time), 'HH24:MI:SS')
                                     FROM cron.job_run_details WHERE status = 'succeeded'), '-')""")
                gen_active, gen_runs, gen_last = cur.fetchone()
            except Exception:                                     # noqa: BLE001
                conn.rollback()
                gen_active, gen_runs, gen_last = "unknown", "0", "-"

            state = fdw_state(cur)

        self._send(200, json.dumps({
            "postgres": {"version": pgver.split()[0], "stations": stations,
                         "approx_trips": approx_trips, "size": size,
                         "first": first, "last": last, "behind_seconds": behind,
                         "last_hour": last_hour},
            "minutes": minutes,
            "cdc": {"state": cdc_state, "slot_active": slot_active,
                    "unconsumed": unconsumed, "published": published},
            "generator": {"active": gen_active, "runs": gen_runs, "last": gen_last},
            "fdw": state,
            "ms": round((time.perf_counter() - t0) * 1000, 1),
        }))

    def _series(self, f):
        key = json.dumps(f.as_dict(), sort_keys=True)

        def produce():
            out, total = {}, 0.0
            with QUERY_SLOT, connect() as conn, conn.cursor() as cur:
                for name, spec in SERIES.items():
                    params = []
                    where, params = f.where("t", "s", params)
                    sql = cur.mogrify(spec["sql"].replace("{where}", where), params)
                    t0 = time.perf_counter()
                    cur.execute(sql)
                    cols = [c.name for c in cur.description]
                    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
                    ms = round((time.perf_counter() - t0) * 1000, 1)
                    total += ms
                    out[name] = {"label": spec["label"], "columns": cols,
                                 "rows": rows, "ms": ms, "sql": sql.strip()}
                    record("series", name,
                           {"where": "postgres", "verdict": "series",
                            "detail": "dashboard chart — local scan, never pushed down"},
                           ms, len(rows), sql.strip(),
                           describe=f.describe(), schema=LOCAL_SCHEMA)
            return {"series": out, "ms": round(total, 1),
                    "filters": f.as_dict(), "describe": f.describe()}

        self._send(200, json.dumps(cached(key, produce)))

    # -- the two halves --------------------------------------------------- #

    def _map(self, name, f):
        if name not in MAP_QUERIES:
            return self._send(404, json.dumps({"error": f"no map query {name!r}"}))
        sql, params = build_map(name, f)
        with QUERY_SLOT, connect() as conn, conn.cursor() as cur:
            sql = cur.mogrify(sql, params)
            # Explained as well, so the Maps panel can say the same things the
            # Statistics panel says. A map is never pushed down, but "never"
            # reads better when the plan is on screen next to the claim.
            v = analyse(explain(cur, sql), fdw_state(cur)["ready"])
            v["verdict"] = "geometry"
            v["detail"] = "PostGIS geometry — there is no remote form of this"
            t0 = time.perf_counter()
            cur.execute(sql)
            geojson = cur.fetchone()[0]
            ms = round((time.perf_counter() - t0) * 1000, 1)
        n = len(geojson.get("features", []))
        record("map", name, v, ms, n, sql, v["nodes"],
               describe=f.describe(), schema=LOCAL_SCHEMA)
        self._send(200, json.dumps({
            "geojson": geojson, "ms": ms, "sql": sql,
            "note": MAP_QUERIES[name]["note"], "ran": v,
            "schema": LOCAL_SCHEMA, "describe": f.describe(),
        }))

    def _agg(self, name, f, side="auto"):
        if name not in AGG_QUERIES:
            return self._send(404, json.dumps({"error": f"no aggregate {name!r}"}))
        with QUERY_SLOT, connect() as conn, conn.cursor() as cur:
            state = fdw_state(cur)
            schema, resolved = pick_schema(side, state)
            sql, params = build_agg(name, f, schema)
            sql = cur.mogrify(sql, params)
            plan = explain(cur, sql)
            v = analyse(plan, state["ready"])
            t0 = time.perf_counter()
            cur.execute(sql)
            cols = [c.name for c in cur.description]
            rows = [[str(x) if x is not None else "" for x in r] for r in cur.fetchall()]
            ms = round((time.perf_counter() - t0) * 1000, 1)
        record("agg", name, v, ms, len(rows), sql, v["nodes"],
               describe=f.describe(), schema=schema)
        self._send(200, json.dumps({
            "columns": cols, "rows": rows, "ms": ms, "sql": sql,
            "ran": v, "schema": schema, "side": resolved,
            "note": AGG_QUERIES[name]["note"],
            "sides_available": {"local": LOCAL_SCHEMA,
                                "foreign": FOREIGN_SCHEMA if state["ready"] else ""},
            "describe": f.describe(),
        }))

    # -- pushdown --------------------------------------------------------- #

    def _pushdown(self, q):
        """Run one aggregate on each side and report what the plans say.

        The comparison is the evidence. One number on its own — "it took 12
        seconds" — says nothing about where the work happened; the pair, with
        the row count each plan admits to moving, says everything.
        """
        name = (q.get("name", ["districts"])[0] or "districts")
        if name not in AGG_QUERIES:
            return self._send(404, json.dumps({"error": f"no aggregate {name!r}"}))
        f = Filters(q)
        analyze = (q.get("analyze", ["0"])[0] == "1")
        sides = []
        with QUERY_SLOT, connect() as conn, conn.cursor() as cur:
            state = fdw_state(cur)
            targets = [("local", LOCAL_SCHEMA)]
            if FOREIGN_SCHEMA and state["ready"]:
                targets.append(("foreign", FOREIGN_SCHEMA))
            for side, schema in targets:
                sql, params = build_agg(name, f, schema)
                sql = cur.mogrify(sql, params)
                try:
                    t0 = time.perf_counter()
                    plan = explain(cur, sql, analyze=analyze)
                    plan_ms = round((time.perf_counter() - t0) * 1000, 1)
                    v = analyse(plan, state["ready"])
                    if analyze:
                        # ANALYZE already ran it; asking twice would double the
                        # cost of the honest option and discourage using it.
                        ms, rows, cols, data = plan_ms, None, [], []
                        exec_ms = plan[0].get("Execution Time")
                        if exec_ms is not None:
                            ms = round(exec_ms, 1)
                    else:
                        t0 = time.perf_counter()
                        cur.execute(sql)
                        cols = [c.name for c in cur.description]
                        data = [[str(x) if x is not None else "" for x in r]
                                for r in cur.fetchall()]
                        ms = round((time.perf_counter() - t0) * 1000, 1)
                        rows = len(data)
                    sides.append({"side": side, "schema": schema, "sql": sql,
                                  "ms": ms, "rows": rows, "columns": cols,
                                  "data": data, "ran": v, "analyzed": analyze})
                    record("pushdown", f"{name} [{side}]", v, ms, rows or 0, sql,
                           v["nodes"], describe=f.describe(), schema=schema)
                except Exception as exc:                          # noqa: BLE001
                    conn.rollback()
                    sides.append({"side": side, "schema": schema, "sql": sql,
                                  "error": f"{type(exc).__name__}: {exc}"})
        self._send(200, json.dumps({
            "name": name, "label": AGG_QUERIES[name]["label"],
            "note": AGG_QUERIES[name]["note"],
            "sides": sides, "fdw": state, "analyzed": analyze,
            "describe": f.describe(),
        }))

    def _log(self):
        with LOG_LOCK:
            entries = list(LOG)
        aggs = [e for e in entries if e["kind"] in ("agg", "pushdown")]
        pushed = sum(1 for e in aggs if e["where"] == "clickhouse")
        local = sum(1 for e in aggs if e["where"] == "postgres")
        self._send(200, json.dumps({
            "entries": entries,
            "summary": {
                "total": len(entries), "aggregates": len(aggs),
                "pushed_down": pushed, "aggregates_run_locally": local,
                "ms_clickhouse": round(sum(e["ms"] for e in entries
                                           if e["where"] == "clickhouse"), 1),
                "ms_postgres": round(sum(e["ms"] for e in entries
                                         if e["where"] != "clickhouse"), 1),
                "rows_crossed": sum(e["crossed"] or 0 for e in entries),
                "agg_schema": AGG_SCHEMA},
        }))


if __name__ == "__main__":
    print(f"listening on :{PORT}; local schema {LOCAL_SCHEMA!r}, "
          f"aggregates read {AGG_SCHEMA!r}, "
          f"foreign schema {FOREIGN_SCHEMA or '(none)'}", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
