"""Chart-shaped queries: aggregate, generate the bucket series, left-join.

A reporting view is SPARSE -- it projects what is stored and nothing more, and
a view cannot emit rows for buckets that do not exist. Gap filling therefore
belongs here, because only a request carries a start, an end and a bucket size.

The shape is always: normalise -> aggregate -> generate -> left-join.

Aggregating first matters. Equality-joining raw observations to a generated
series only works when the bucket is exactly one hour and the start aligns to
HA's hourly timestamps; at any other bucket it silently drops nearly every
observation and returns a chart that renders, looks fine, and is mostly empty.

RANGE SEMANTICS -- two different contracts, deliberately:

  sub-daily buckets   INSTANT range, half-open [start, end).
                      Every bucket overlapping the range is returned, including
                      the partial one containing `end - epsilon`.
                      Edges are LOCAL wall clock, so a 6-hour bucket starts at
                      00/06/12/18 local rather than wherever those land after a
                      UTC offset. Selection is still by instant -- only the
                      grid the observations are binned onto is local.

  bucket=day          LOCAL CALENDAR range, half-open [start_date, end_date),
                      where the dates are the local dates of `start` and `end`.
                      Complete local days only; the day containing `end` is
                      excluded. So `days=7` yields the seven complete days
                      before today rather than six plus a partial today, which
                      would otherwise read as a consumption drop.

Both the aggregation filter and the generated series use the SAME convention on
each path. Mixing them -- filtering observations by an instant range while
generating local calendar days -- produced partial edge days for temperature and
power, and let energy return whole local days that reached outside the
requested instants.
"""
from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from .limits import BUCKETS

# Local time is applied ONLY at this boundary. Everything is stored in UTC.
LOCAL_TZ = "America/Los_Angeles"
_LOCAL = ZoneInfo(LOCAL_TZ)

# Sub-daily buckets: date_bin with an explicit origin so bucket edges are
# stable regardless of the requested start.
#
# The origin is a LOCAL wall clock, and observations are binned after conversion
# to local time. A fixed UTC instant cannot do this job: it aligns to local
# midnight in at most one DST phase, so an origin chosen to look right in
# January puts every 6-hour bucket at 01/07/13/19 for the eight months of PDT.
# Binning on the wall clock is right in both phases. The cost is that a bucket
# spanning a DST transition covers 5 or 7 real hours instead of 6 -- the same
# trade `bucket=day` already makes for 23- and 25-hour local days, and the same
# one a reader means by "6am".
_ORIGIN = "2000-01-01 00:00:00"

# Local-day bounds as instants, so the WHERE clause stays sargable on start_at
# rather than wrapping it in a timezone conversion.
_DAY_BOUNDS = """
    bounds AS (
        SELECT (%(start)s AT TIME ZONE %(tz)s)::date AS d0,
               (%(end)s   AT TIME ZONE %(tz)s)::date AS d1
    ),
    span AS (
        SELECT d0, d1,
               (d0::timestamp AT TIME ZONE %(tz)s) AS lo,
               (d1::timestamp AT TIME ZONE %(tz)s) AS hi
        FROM bounds
    )
"""


def _measurement_sql(view: str, bucket: str) -> str:
    """Temperature and power: mean of means, min of mins, max of maxes.

    Unweighted, because mean_weight is NULL for every row in this Home
    Assistant version (measured). That is exact here anyway: all source buckets
    are equal-duration hours, so an unweighted mean of hourly means is the true
    mean whenever the bucket is complete.
    """
    value_cols = ("avg(mean_c) AS mean, min(min_c) AS min, max(max_c) AS max"
                  if view == "ha_temperature"
                  else "avg(mean_w) AS mean, min(min_w) AS min, max(max_w) AS max")

    if bucket == "day":
        return f"""
            WITH {_DAY_BOUNDS},
            agg AS (
                SELECT v.statistic_id,
                       (v.start_at AT TIME ZONE %(tz)s)::date AS bucket,
                       {value_cols}
                FROM reporting.{view} v, span
                WHERE v.statistic_id = ANY(%(ids)s::text[])
                  AND v.start_at >= span.lo AND v.start_at < span.hi
                GROUP BY 1, 2
            ),
            series AS (
                SELECT g::date AS bucket
                FROM span, generate_series(
                    span.d0, span.d1 - 1, interval '1 day') g
            )
            SELECT m.statistic_id, s.bucket::text AS bucket,
                   a.mean, a.min, a.max
            FROM series s
            CROSS JOIN unnest(%(ids)s::text[]) AS m(statistic_id)
            LEFT JOIN agg a ON a.bucket = s.bucket
                           AND a.statistic_id = m.statistic_id
            ORDER BY m.statistic_id, s.bucket
        """

    return f"""
        WITH agg AS (
            -- Filter by INSTANT, bin by LOCAL wall clock. The WHERE clause is
            -- left on the raw start_at so it stays sargable; only the binning
            -- expression pays for the conversion.
            SELECT statistic_id,
                   date_bin(%(step)s::interval,
                            start_at AT TIME ZONE %(tz)s,
                            %(origin)s::timestamp) AS bucket,
                   {value_cols}
            FROM reporting.{view}
            WHERE statistic_id = ANY(%(ids)s::text[])
              AND start_at >= %(start)s AND start_at < %(end)s
            GROUP BY 1, 2
        ),
        series AS (
            -- Generate through the bucket CONTAINING `end - epsilon`, not
            -- `end - step`. The latter stops one bucket early whenever the
            -- range is unaligned: for 00:30->02:30 hourly it emitted 00:00 and
            -- 01:00 while the 02:00 bucket was aggregated and then discarded,
            -- losing real observations without any error.
            --
            -- Generated on the same local grid the aggregate is binned onto:
            -- every observation in [start, end) has a local time within
            -- [start_local, (end - epsilon)_local], so its bin is always one
            -- the series emits and no aggregate is computed then dropped.
            SELECT g AS bucket
            FROM generate_series(
                date_bin(%(step)s::interval, %(start)s AT TIME ZONE %(tz)s,
                         %(origin)s::timestamp),
                date_bin(%(step)s::interval,
                         (%(end)s - interval '1 microsecond') AT TIME ZONE %(tz)s,
                         %(origin)s::timestamp),
                %(step)s::interval) g
        )
        -- The bucket is already a local wall clock; _bucket_label re-attaches
        -- the offset that makes it an instant again. Doing that here would mean
        -- rendering a zone-aware offset in SQL, which to_char cannot do for
        -- anything but the session timezone.
        SELECT m.statistic_id, s.bucket, a.mean, a.min, a.max
        FROM series s
        CROSS JOIN unnest(%(ids)s::text[]) AS m(statistic_id)
        LEFT JOIN agg a ON a.bucket = s.bucket
                       AND a.statistic_id = m.statistic_id
        ORDER BY m.statistic_id, s.bucket
    """


def _bucket_label(b: datetime) -> str:
    """Stamp the zone onto a naive local bucket edge.

    Plotly has no timezone support: dateTime2ms parses the fields of a date
    string and throws the offset away, so the wall clock in the string is
    verbatim what the axis prints. Labelling in UTC therefore put a 6pm room
    temperature peak at 1am -- the data was right and only the axis lied.

    The offset is still carried on the wire. Plotly ignores it, but it is what
    makes the value an instant rather than an ambiguous local reading, which
    matters for one hour every autumn and for any consumer that is not Plotly.
    That hour is also why this is `replace` and not `astimezone`: the value
    arrives as a wall clock with no zone, so the zone is ATTACHED, never
    converted. fold=0 resolves the repeated hour to its first occurrence, which
    is the one the bucket's observations start in.
    """
    return b.replace(tzinfo=_LOCAL).isoformat()


def measurement_series(conn, view: str, ids: list[str], start: datetime,
                       end: datetime, bucket: str) -> dict:
    step = BUCKETS[bucket]
    params = {"ids": ids, "start": start, "end": end, "tz": LOCAL_TZ,
              "origin": _ORIGIN}
    if step is not None:
        params["step"] = step

    with conn.cursor() as cur:
        cur.execute(_measurement_sql(view, bucket), params)
        rows = cur.fetchall()

    # Day buckets are already local calendar dates and arrive as text; every
    # other bucket arrives as an instant and is labelled here.
    label = str if step is None else _bucket_label

    out: dict[str, list] = {sid: [] for sid in ids}
    for sid, b, mean, mn, mx in rows:
        # Explicit nulls, never omitted points: Plotly's connectgaps=false only
        # breaks a line where the trace actually contains a null. Dropping the
        # empty buckets would draw a straight line across an outage.
        out[sid].append({"bucket": label(b),
                         "mean": float(mean) if mean is not None else None,
                         "min": float(mn) if mn is not None else None,
                         "max": float(mx) if mx is not None else None})
    return out


ENERGY_DAILY_SQL = f"""
    WITH {_DAY_BOUNDS},
    series AS (
        SELECT g::date AS bucket
        FROM span, generate_series(span.d0, span.d1 - 1, interval '1 day') g
    )
    SELECT m.statistic_id, s.bucket::text AS bucket,
           d.allocated_kwh, d.unallocated_kwh, d.unresolved_kwh,
           d.temporal_coverage, d.allocation_coverage
    FROM series s
    CROSS JOIN unnest(%(ids)s::text[]) AS m(statistic_id)
    LEFT JOIN reporting.ha_energy_daily d
           ON d.local_day = s.bucket AND d.statistic_id = m.statistic_id
    ORDER BY m.statistic_id, s.bucket
"""


def energy_daily(conn, ids: list[str], start: datetime, end: datetime) -> dict:
    """Daily energy, already DST-safe in the view (it sums hourly deltas).

    The join is now clipped to the same local-calendar window the series
    generates, so a day outside [start_date, end_date) can no longer appear.

    Coverage travels with the numbers rather than being computed client-side,
    so a partially observed day cannot be mistaken for a low-consumption one.
    """
    with conn.cursor() as cur:
        cur.execute(ENERGY_DAILY_SQL,
                    {"ids": ids, "start": start, "end": end, "tz": LOCAL_TZ})
        rows = cur.fetchall()

    out: dict[str, list] = {sid: [] for sid in ids}
    for sid, b, alloc, unalloc, unres, tcov, acov in rows:
        out[sid].append({
            "bucket": b,
            "allocated_kwh": float(alloc) if alloc is not None else None,
            "unallocated_kwh": float(unalloc) if unalloc is not None else None,
            "unresolved_kwh": float(unres) if unres is not None else None,
            "temporal_coverage": float(tcov) if tcov is not None else None,
            "allocation_coverage": float(acov) if acov is not None else None,
        })
    return out


ENERGY_BILLING_SQL = """
    SELECT statistic_id, display_name, grain,
           covered_from, covered_until, covered_hours,
           delta_kwh, delta_source, review_decision, quality_flags,
           billable_kwh
    FROM reporting.ha_energy_billing
    WHERE statistic_id = ANY(%(ids)s::text[])
      AND (
        -- Seeded rows (first of an imported series) have covered_from = NULL:
        -- there is no predecessor to span from, so they are POINTS, not
        -- intervals, and take point-in-range semantics. A COALESCE'd interval
        -- test gets this wrong at the lower edge -- with covered_until > start
        -- a request beginning exactly at the seeded timestamp excludes the very
        -- row it is asking for.
        (covered_from IS NULL
         AND covered_until >= %(start)s AND covered_until < %(end)s)
        OR
        -- Ordinary intervals: strict half-open overlap. A period ending exactly
        -- AT start shares no instant with [start, end).
        (covered_from IS NOT NULL
         AND covered_until > %(start)s AND covered_from < %(end)s)
      )
    ORDER BY statistic_id, covered_until
    LIMIT %(limit)s
"""


def energy_billing(conn, ids: list[str], start: datetime, end: datetime,
                   limit: int) -> tuple[dict, bool]:
    """Utility history at its NATIVE grain -- billing periods and days.

    No gap generation: these intervals are irregular by nature (measured on this
    account: 15-34 days across 7 distinct lengths), so there is no grid to fill
    against. Rows carry their own covered_from/covered_until instead.

    A row is included when its covered interval OVERLAPS the request, since a
    billing period straddling the boundary is still the period the caller is
    asking about.
    """
    with conn.cursor() as cur:
        cur.execute(ENERGY_BILLING_SQL,
                    {"ids": ids, "start": start, "end": end, "limit": limit + 1})
        rows = cur.fetchall()

    truncated = len(rows) > limit
    out: dict[str, list] = {sid: [] for sid in ids}
    for r in rows[:limit]:
        out[r[0]].append({
            "grain": r[2],
            "covered_from": r[3].isoformat() if r[3] else None,
            "covered_until": r[4].isoformat() if r[4] else None,
            "covered_hours": float(r[5]) if r[5] is not None else None,
            "delta_kwh": float(r[6]) if r[6] is not None else None,
            "delta_source": r[7],
            "review_decision": r[8],
            "quality_flags": list(r[9]) if r[9] else [],
            "billable_kwh": float(r[10]) if r[10] is not None else None,
        })
    return out, truncated
