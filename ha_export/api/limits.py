"""Request limits and query-parameter validation.

Gap filling makes it trivial to ask for an enormous result: the response size is
driven by the REQUESTED range, not by how much data exists. Seven years of
hourly buckets across 27 metrics is ~1.6M points, which must be refused rather
than served. Every limit here exists to keep one request from doing that.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

# Bucket sizes the API will aggregate into. `day` is special-cased downstream:
# it is a LOCAL CALENDAR day, not a fixed 24h span, so DST is handled correctly.
BUCKETS = {
    "hour": timedelta(hours=1),
    "2hour": timedelta(hours=2),
    "6hour": timedelta(hours=6),
    "day": None,
}

MAX_BUCKETS = 5000        # points per series
MAX_METRICS = 12          # series per request
MAX_TOTAL_POINTS = 20000  # buckets * metrics
MAX_RANGE_DAYS = 3660     # ~10 years, enough for the whole opower history
MAX_BILLING_ROWS = 2000   # native-grain rows per billing request

# Must match queries.LOCAL_TZ; imported there rather than duplicated would be
# circular, so it is asserted equal by a test instead.
LOCAL_TZ = "America/Los_Angeles"


class BadRequest(Exception):
    def __init__(self, message: str):
        self.message = message


def parse_range(args, default_days: int = 7) -> tuple[datetime, datetime]:
    """Resolve and validate the requested [start, end) window, in UTC."""
    now = datetime.now(timezone.utc)

    def parse(name: str, default: datetime) -> datetime:
        raw = args.get(name)
        if not raw:
            return default
        try:
            dt = datetime.fromisoformat(raw)
        except ValueError:
            raise BadRequest(
                f"{name}={raw!r} is not an ISO 8601 date or datetime")
        # Naive input is treated as UTC; offset-bearing input is CONVERTED,
        # never relabelled -- relabelling would silently shift the window.
        return (dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None
                else dt.astimezone(timezone.utc))

    if args.get("days"):
        try:
            days = int(args["days"])
        except ValueError:
            raise BadRequest(f"days={args['days']!r} is not an integer")
        if days < 1:
            raise BadRequest("days must be >= 1")
        start, end = now - timedelta(days=days), now
    else:
        end = parse("end", now)
        start = parse("start", end - timedelta(days=default_days))

    if end <= start:
        raise BadRequest("end must be strictly after start (the range is "
                         "half-open [start, end))")
    if (end - start) > timedelta(days=MAX_RANGE_DAYS):
        raise BadRequest(f"range exceeds the {MAX_RANGE_DAYS}-day maximum")
    return start, end


def parse_bucket(args, default: str = "hour") -> str:
    bucket = args.get("bucket", default)
    if bucket not in BUCKETS:
        raise BadRequest(f"bucket={bucket!r} must be one of "
                         f"{sorted(BUCKETS)}")
    return bucket


def bucket_count(start: datetime, end: datetime, bucket: str) -> int:
    """How many points one series will contain.

    Must match queries.py exactly, or the guard protects against a different
    request than the one actually executed.

      sub-daily : instant range, every bucket overlapping [start, end),
                  i.e. through the bucket containing end - epsilon
      day       : local calendar days [start_date, end_date), so complete days
                  only and the day containing `end` excluded
    """
    step = BUCKETS[bucket]
    if step is None:
        tz = ZoneInfo(LOCAL_TZ)
        d0 = start.astimezone(tz).date()
        d1 = end.astimezone(tz).date()
        return max((d1 - d0).days, 0)

    secs = step.total_seconds()
    first = int(start.timestamp() // secs)
    last = int((end - timedelta(microseconds=1)).timestamp() // secs)
    return max(last - first + 1, 0)


def check_size(start: datetime, end: datetime, bucket: str,
               metric_count: int) -> int:
    """Reject a request whose gap-filled result would be too large.

    Checked BEFORE querying, because the cost is in generating and serialising
    the buckets, not in the rows that happen to exist.
    """
    if metric_count > MAX_METRICS:
        raise BadRequest(f"{metric_count} metrics requested; the maximum is "
                         f"{MAX_METRICS}. Narrow the selection.")
    if metric_count == 0:
        raise BadRequest("no metrics matched the request")

    buckets = bucket_count(start, end, bucket)

    if buckets > MAX_BUCKETS:
        raise BadRequest(
            f"that range at bucket={bucket} is {buckets} points per series, "
            f"over the {MAX_BUCKETS} limit. Use a coarser bucket or a "
            f"shorter range.")
    if buckets * metric_count > MAX_TOTAL_POINTS:
        raise BadRequest(
            f"{buckets} points x {metric_count} metrics = "
            f"{buckets * metric_count} total, over the {MAX_TOTAL_POINTS} "
            f"limit. Narrow the range or the metric selection.")
    return buckets
