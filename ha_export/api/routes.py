"""homelab-api endpoints.

Everything returns chart-shaped JSON -- arrays of {bucket, ...} with explicit
nulls at empty buckets -- so the frontend does no reshaping.
"""
from __future__ import annotations

from flask import Blueprint, current_app, jsonify, request

from .auth import requires_auth
from .db import get_conn
from .limits import (MAX_BILLING_ROWS, MAX_METRICS, BadRequest, check_size,
                     parse_bucket, parse_range)
from .queries import energy_billing, energy_daily, measurement_series

bp = Blueprint("api", __name__)

CATEGORY_VIEW = {
    "environmental_temperature": "ha_temperature",
    "machine_temperature": "ha_temperature",
    "device_power": "ha_power",
}


def _resolve_ids(conn, categories: list[str], requested: list[str],
                 include_inactive: bool = False) -> list[tuple[str, str]]:
    """Metric ids the caller is asking for, as (statistic_id, display_name).

    Selection always goes through the catalog, so a caller cannot reach a
    metric that is not in the reviewed allowlist by naming it directly.
    """
    sql = ["""SELECT statistic_id, display_name FROM reporting.ha_source_status
              WHERE category = ANY(%(cats)s)"""]
    params: dict = {"cats": categories}
    if not include_inactive:
        sql.append("AND is_active")
    if requested:
        sql.append("AND statistic_id = ANY(%(ids)s)")
        params["ids"] = requested
    sql.append("ORDER BY display_name")
    with conn.cursor() as cur:
        cur.execute(" ".join(sql), params)
        return cur.fetchall()


def _listarg(name: str) -> list[str]:
    raw = request.args.get(name)
    return [v for v in (raw.split(",") if raw else []) if v]


@bp.get("/api/health")
def health():
    """Unauthenticated liveness probe for the container healthcheck."""
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
        return jsonify(status="ok")
    except Exception as exc:             # noqa: BLE001
        current_app.logger.warning("health check failed: %s", exc)
        return jsonify(status="degraded", detail="database unreachable"), 503


@bp.get("/api/metrics")
@requires_auth
def metrics(current_user=None):
    """The catalog, so the dashboard can build its selectors."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("""SELECT statistic_id, display_name, category, is_active,
                              last_value_at, stale_for > interval '2 hours'
                       FROM reporting.ha_source_status ORDER BY category, display_name""")
        rows = cur.fetchall()
    return jsonify(metrics=[
        {"statistic_id": r[0], "display_name": r[1], "category": r[2],
         "is_active": r[3],
         "last_value_at": r[4].isoformat() if r[4] else None,
         "stale": bool(r[5]) if r[5] is not None else True}
        for r in rows])


@bp.get("/api/temperature")
@requires_auth
def temperature(current_user=None):
    categories = _listarg("category") or ["environmental_temperature"]
    unknown = set(categories) - {"environmental_temperature", "machine_temperature"}
    if unknown:
        raise BadRequest(f"unknown category: {sorted(unknown)}")

    start, end = parse_range(request.args)
    bucket = parse_bucket(request.args)
    with get_conn() as conn:
        found = _resolve_ids(conn, categories, _listarg("metric"))
        check_size(start, end, bucket, len(found))
        series = measurement_series(
            conn, "ha_temperature", [r[0] for r in found], start, end, bucket)
    return jsonify(unit="degC", bucket=bucket,
                   start=start.isoformat(), end=end.isoformat(),
                   series=[{"statistic_id": sid, "display_name": name,
                            "points": series[sid]} for sid, name in found])


@bp.get("/api/power")
@requires_auth
def power(current_user=None):
    start, end = parse_range(request.args)
    bucket = parse_bucket(request.args)
    with get_conn() as conn:
        found = _resolve_ids(conn, ["device_power"], _listarg("metric"))
        check_size(start, end, bucket, len(found))
        series = measurement_series(
            conn, "ha_power", [r[0] for r in found], start, end, bucket)
    return jsonify(unit="W", bucket=bucket,
                   start=start.isoformat(), end=end.isoformat(),
                   series=[{"statistic_id": sid, "display_name": name,
                            "points": series[sid]} for sid, name in found])


@bp.get("/api/energy/daily")
@requires_auth
def energy(current_user=None):
    categories = _listarg("category") or ["device_energy"]
    unknown = set(categories) - {"device_energy", "home_energy"}
    if unknown:
        raise BadRequest(f"unknown category: {sorted(unknown)}")

    start, end = parse_range(request.args, default_days=30)
    with get_conn() as conn:
        found = _resolve_ids(conn, categories, _listarg("metric"))
        check_size(start, end, "day", len(found))
        series = energy_daily(conn, [r[0] for r in found], start, end)
    return jsonify(unit="kWh", bucket="day",
                   start=start.isoformat(), end=end.isoformat(),
                   series=[{"statistic_id": sid, "display_name": name,
                            "points": series[sid]} for sid, name in found])


@bp.get("/api/status")
@requires_auth
def status(current_user=None):
    """Freshness per metric, so the dashboard can show a stale badge rather
    than a flat line that reads as real data."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("""SELECT statistic_id, display_name, category, is_active,
                              grain_review_required, last_value_at,
                              extract(epoch FROM stale_for), rows_imported,
                              last_success_at, last_error
                       FROM reporting.ha_source_status
                       ORDER BY category, display_name""")
        rows = cur.fetchall()
    return jsonify(sources=[
        {"statistic_id": r[0], "display_name": r[1], "category": r[2],
         "is_active": r[3], "grain_review_required": r[4],
         "last_value_at": r[5].isoformat() if r[5] else None,
         "stale_seconds": float(r[6]) if r[6] is not None else None,
         "rows_imported": r[7],
         "last_success_at": r[8].isoformat() if r[8] else None,
         "last_error": r[9]}
        for r in rows])


@bp.get("/api/energy/billing")
@requires_auth
def billing(current_user=None):
    """Utility history at its NATIVE grain: billing periods and days.

    Separate from /api/energy/daily because these intervals are irregular and
    cannot be placed on a fixed grid -- presenting a 29-day billing period as a
    calendar month, or splitting it across days, would both be fabrications.
    Each row carries its own covered interval, quality flags and review state.
    """
    start, end = parse_range(request.args, default_days=3650)
    with get_conn() as conn:
        found = _resolve_ids(conn, ["home_energy"], _listarg("metric"),
                             include_inactive=True)
        if not found:
            raise BadRequest("no metrics matched the request")
        if len(found) > MAX_METRICS:
            raise BadRequest(f"{len(found)} metrics requested; the maximum is "
                             f"{MAX_METRICS}")
        series, truncated = energy_billing(
            conn, [r[0] for r in found], start, end, MAX_BILLING_ROWS)
    return jsonify(unit="kWh", grain="native", truncated=truncated,
                   start=start.isoformat(), end=end.isoformat(),
                   series=[{"statistic_id": sid, "display_name": name,
                            "periods": series[sid]} for sid, name in found])
