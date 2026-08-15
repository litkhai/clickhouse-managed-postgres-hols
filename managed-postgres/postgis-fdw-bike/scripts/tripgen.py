#!/usr/bin/env python3
"""Generate bike trips shaped like the ones already loaded.

Reads a sample of real trips on stdin (CSV, produced by the calling script),
writes generated trips to stdout in bike.trips column order, ready for COPY.

    tripgen.py --from 2026-02-01 --to 2026-08-15 [--scale 1.0] [--seed 7]
    tripgen.py --minutes 5                      # a live window ending now

Why resample rather than invent
-------------------------------
Every field here correlates with every other. Morning trips run station-to-
subway and last eight minutes; Sunday afternoon trips run along the river and
last forty. Rider age shifts with both. Drawing each column from its own
marginal distribution would reproduce all the histograms and none of the joint
structure — the OD matrix would go uniform, and the aggregates this lab exists
to demonstrate would flatten out.

So a generated trip is a real trip with a new timestamp, drawn from the pool of
real trips that started in the *same hour of the same kind of day*. That keeps
hour-of-day tied to origin, destination, duration and rider. Only the volume
per day and the timestamps are synthetic; durations get a little noise so
repeated draws are not byte-identical.

What is measured and what is assumed
------------------------------------
Measured from the loaded month: the hourly shape (weekday and weekend
separately), the ratio between them, and the pool of trips itself.

Assumed: the month-to-month scale. Seoul's bike traffic more than doubles from
January to June, and the published monthly file sizes are a usable proxy for
trip counts — 280, 307, 501, 674, 690, 716 MB for 2026-01 to 2026-06. Those
ratios are used below. July and August are not published yet, so they are
extrapolated from June and flagged as such by --explain.
"""
import argparse
import csv
import datetime as dt
import random
import sys

# Relative volume by month, from the portal's published file sizes divided by
# January's. July and August are guesses: usage typically falls back in the
# monsoon and the worst of the heat, so they are set just under June.
MONTH_SCALE = {
    1: 1.00, 2: 1.09, 3: 1.79, 4: 2.40, 5: 2.46, 6: 2.56,
    7: 2.20, 8: 2.25, 9: 2.50, 10: 2.45, 11: 1.70, 12: 1.10,
}
EXTRAPOLATED_MONTHS = {7, 8, 9, 10, 11, 12}

COLUMNS = [
    "bike_id", "started_at", "start_station_id", "start_station_name", "start_rack",
    "ended_at", "end_station_id", "end_station_name", "end_rack", "duration_min",
    "distance_m", "birth_year", "gender", "user_type",
    "start_station_code", "end_station_code",
]


def load_pool(stream):
    """Bucket the sample by (is_weekend, hour) so draws keep that correlation."""
    pool, hourly, daily = {}, {(False, h): 0 for h in range(24)}, {}
    hourly.update({(True, h): 0 for h in range(24)})
    for row in csv.DictReader(stream):
        started = dt.datetime.fromisoformat(row["started_at"])
        weekend = started.weekday() >= 5
        key = (weekend, started.hour)
        pool.setdefault(key, []).append(row)
        hourly[key] += 1
        daily.setdefault(started.date(), 0)
        daily[started.date()] += 1
    if not pool:
        sys.exit("tripgen: the sample was empty")
    return pool, hourly, daily


def hour_weights(hourly):
    """Share of a day's trips falling in each hour, per kind of day."""
    out = {}
    for weekend in (False, True):
        total = sum(hourly[(weekend, h)] for h in range(24))
        if total == 0:
            sys.exit(f"tripgen: no {'weekend' if weekend else 'weekday'} trips in the sample")
        out[weekend] = [hourly[(weekend, h)] / total for h in range(24)]
    return out


def day_volumes(daily):
    """Mean trips on a weekday and on a weekend day, from the sample's own days.

    Partial days at either end of the loaded month would drag the mean down, so
    the lowest and highest day of each kind are dropped before averaging.
    """
    weekday = sorted(n for d, n in daily.items() if d.weekday() < 5)
    weekend = sorted(n for d, n in daily.items() if d.weekday() >= 5)
    trim = lambda xs: xs[1:-1] if len(xs) > 4 else xs
    weekday, weekend = trim(weekday), trim(weekend)
    return (sum(weekday) / len(weekday) if weekday else 0,
            sum(weekend) / len(weekend) if weekend else 0)


def poisson(rng, mean):
    """Draw from Poisson(mean). Normal approximation above 30, where Knuth's
    product method needs thousands of multiplications and the two agree."""
    if mean <= 0:
        return 0
    if mean > 30:
        return max(0, round(rng.gauss(mean, mean ** 0.5)))
    import math
    limit, k, p = math.exp(-mean), 0, 1.0
    while True:
        p *= rng.random()
        if p <= limit:
            return k
        k += 1


def emit(writer, template, started, rng):
    """One generated trip: a real one, moved in time and jittered."""
    duration = template["duration_min"]
    duration = int(duration) if duration not in ("", None) else 0
    # +/-20%, so repeated draws of the same template are not identical, but a
    # 3-minute hop never becomes a 30-minute one.
    duration = max(0, round(duration * rng.uniform(0.8, 1.2)))

    distance = template["distance_m"]
    if distance not in ("", None) and float(distance) > 0:
        base = float(distance)
        original = int(template["duration_min"] or 0) or 1
        # Keep implied speed plausible by scaling distance with the same factor.
        distance = round(base * duration / original, 2) if original else base
    else:
        distance = 0.00

    ended = started + dt.timedelta(minutes=duration)
    writer.writerow([
        template["bike_id"],
        started.isoformat(sep=" ", timespec="seconds"),
        template["start_station_id"], template["start_station_name"], template["start_rack"],
        ended.isoformat(sep=" ", timespec="seconds"),
        template["end_station_id"], template["end_station_name"], template["end_rack"],
        duration, f"{distance:.2f}",
        template["birth_year"], template["gender"], template["user_type"],
        template["start_station_code"], template["end_station_code"],
    ])


def generate_day(writer, day, pool, weights, base_weekday, base_weekend, scale, rng):
    weekend = day.weekday() >= 5
    base = base_weekend if weekend else base_weekday
    # Day-to-day variation on top of the seasonal factor: weather, mostly.
    volume = int(base * MONTH_SCALE.get(day.month, 1.0) * scale * rng.uniform(0.82, 1.18))
    written = 0
    for hour in range(24):
        count = int(volume * weights[weekend][hour])
        bucket = pool.get((weekend, hour)) or pool.get((not weekend, hour))
        if not bucket or count <= 0:
            continue
        for _ in range(count):
            started = dt.datetime.combine(day, dt.time(hour)) + dt.timedelta(
                seconds=rng.randrange(3600))
            emit(writer, rng.choice(bucket), started, rng)
            written += 1
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="start", help="first day, YYYY-MM-DD")
    ap.add_argument("--to", dest="end", help="last day, YYYY-MM-DD (inclusive)")
    ap.add_argument("--minutes", type=int, help="instead: a window of N minutes ending now")
    ap.add_argument("--days-file", help="instead: one YYYY-MM-DD per line, only those days")
    ap.add_argument("--weekday-base", type=float, help="real trips on an average weekday")
    ap.add_argument("--weekend-base", type=float, help="real trips on an average weekend day")
    ap.add_argument("--scale", type=float, default=1.0, help="multiply every day's volume")
    ap.add_argument("--seed", type=int, default=None, help="fix the randomness")
    ap.add_argument("--explain", action="store_true", help="describe the plan on stderr, write nothing")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    pool, hourly, daily = load_pool(sys.stdin)
    weights = hour_weights(hourly)
    # Prefer the real per-day averages measured over the whole table. Deriving
    # them from the sample was wrong: the sample is a slice, so "trips per day
    # in the sample" is not trips per day, and a slice that happened to land on
    # the New Year holiday reported weekends as busier than weekdays — the
    # opposite of the truth.
    base_weekday, base_weekend = day_volumes(daily)
    if args.weekday_base:
        base_weekday = args.weekday_base
    if args.weekend_base:
        base_weekend = args.weekend_base
    writer = csv.writer(sys.stdout)

    if args.minutes:
        now = dt.datetime.now().replace(microsecond=0)
        window_start = now - dt.timedelta(minutes=args.minutes)
        weekend = now.weekday() >= 5
        base = base_weekend if weekend else base_weekday
        per_hour = base * MONTH_SCALE.get(now.month, 1.0) * args.scale * weights[weekend][now.hour]
        # Arrivals vary; without this every window of the same length returns
        # exactly the same count and the "live" feed looks like a metronome.
        # Poisson is the right shape for independent arrivals, and its spread
        # narrows as the count grows, which is also what real traffic does.
        expected = per_hour * args.minutes / 60
        count = max(1, poisson(rng, expected))
        if args.explain:
            print(f"  {count} trips over the last {args.minutes} min "
                  f"({'weekend' if weekend else 'weekday'} hour {now.hour})", file=sys.stderr)
            return 0
        bucket = pool.get((weekend, now.hour)) or next(iter(pool.values()))
        for _ in range(count):
            started = window_start + dt.timedelta(seconds=rng.randrange(args.minutes * 60))
            emit(writer, rng.choice(bucket), started, rng)
        print(f"  {count} trips", file=sys.stderr)
        return 0

    if args.days_file:
        with open(args.days_file) as fh:
            days = [dt.date.fromisoformat(line.strip()) for line in fh if line.strip()]
        if not days:
            print("  nothing to fill: no missing days", file=sys.stderr)
            return 0
        first, last = min(days), max(days)
    elif args.start and args.end:
        first = dt.date.fromisoformat(args.start)
        last = dt.date.fromisoformat(args.end)
        if last < first:
            sys.exit("tripgen: --to is before --from")
        days = [first + dt.timedelta(days=i) for i in range((last - first).days + 1)]
    else:
        sys.exit("tripgen: give --days-file, or --from and --to, or --minutes")

    if args.explain:
        total, months = 0, set()
        for day in days:
            base = base_weekend if day.weekday() >= 5 else base_weekday
            total += base * MONTH_SCALE.get(day.month, 1.0) * args.scale
            months.add(day.month)
        print(f"  sample     : {sum(len(v) for v in pool.values())} trips", file=sys.stderr)
        print(f"  baseline   : {base_weekday:,.0f} weekday / {base_weekend:,.0f} weekend per day",
              file=sys.stderr)
        print(f"  days       : {len(days)} missing, {first} .. {last}", file=sys.stderr)
        print(f"  estimate   : {total:,.0f} trips at scale {args.scale}", file=sys.stderr)
        guessed = sorted(months & EXTRAPOLATED_MONTHS)
        if guessed:
            print(f"  extrapolated months (no published data): {guessed}", file=sys.stderr)
        return 0

    written = 0
    for day in days:
        written += generate_day(writer, day, pool, weights,
                                base_weekday, base_weekend, args.scale, rng)
    print(f"  {written:,} trips across {len(days)} days ({first} .. {last})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
