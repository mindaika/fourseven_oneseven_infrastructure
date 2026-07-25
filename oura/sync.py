#!/usr/bin/env python3
"""Weekly Oura Ring data sync into the `oura` Postgres schema.

Run via oura-sync.sh (cron, weekly) or by hand: `python3 sync.py`.

For each endpoint, this pulls everything since the last successful sync
(tracked in oura.sync_log) and upserts it, so re-runs and missed weeks are
both safe — nothing is skipped and nothing is duplicated.

Requires OURA_ACCESS_TOKEN and OURA_DATABASE_URL, read from oura/.env
(get a token at https://cloud.ouraring.com/personal-access-tokens).
"""
import json
import os
import sys
from datetime import date, timedelta
from pathlib import Path

import psycopg
import requests

API_BASE = "https://api.ouraring.com/v2/usercollection"
ENV_PATH = Path(__file__).parent / ".env"

# How far back to pull on the very first run for an endpoint (before any
# sync_log history exists). Subsequent runs pick up from the last window_end.
INITIAL_BACKFILL_DAYS = int(os.environ.get("OURA_INITIAL_BACKFILL_DAYS", "90"))


def load_env():
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip())


def fetch_paginated(session, endpoint, start_date, end_date):
    """Yield every record from an Oura v2 usercollection endpoint, following
    next_token pagination."""
    params = {"start_date": start_date.isoformat(), "end_date": end_date.isoformat()}
    while True:
        resp = session.get(f"{API_BASE}/{endpoint}", params=params, timeout=30)
        resp.raise_for_status()
        payload = resp.json()
        yield from payload.get("data", [])
        next_token = payload.get("next_token")
        if not next_token:
            return
        params["next_token"] = next_token


def last_window_end(conn, endpoint):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT window_end FROM oura.sync_log "
            "WHERE endpoint = %s AND status = 'success' "
            "ORDER BY window_end DESC LIMIT 1",
            (endpoint,),
        )
        row = cur.fetchone()
    return row[0] if row else date.today() - timedelta(days=INITIAL_BACKFILL_DAYS)


def start_sync_log(conn, endpoint, window_start, window_end):
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO oura.sync_log (endpoint, window_start, window_end) "
            "VALUES (%s, %s, %s) RETURNING id",
            (endpoint, window_start, window_end),
        )
        log_id = cur.fetchone()[0]
    conn.commit()
    return log_id


def finish_sync_log(conn, log_id, status, records_synced, error=None):
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE oura.sync_log SET completed_at = now(), status = %s, "
            "records_synced = %s, error = %s WHERE id = %s",
            (status, records_synced, error, log_id),
        )
    conn.commit()


def sync_day_scored(conn, session, endpoint, table, start_date, end_date):
    """Endpoints shaped like {id, day, score, ...}: daily_activity,
    daily_sleep, daily_readiness."""
    count = 0
    with conn.cursor() as cur:
        for rec in fetch_paginated(session, endpoint, start_date, end_date):
            cur.execute(
                f"""INSERT INTO oura.{table} (id, day, score, data, synced_at)
                    VALUES (%s, %s, %s, %s, now())
                    ON CONFLICT (id) DO UPDATE
                    SET day = excluded.day, score = excluded.score,
                        data = excluded.data, synced_at = now()""",
                (rec["id"], rec["day"], rec.get("score"), json.dumps(rec)),
            )
            count += 1
    conn.commit()
    return count


def sync_sleep_periods(conn, session, start_date, end_date):
    count = 0
    with conn.cursor() as cur:
        for rec in fetch_paginated(session, "sleep", start_date, end_date):
            cur.execute(
                """INSERT INTO oura.sleep_periods
                       (id, day, bedtime_start, bedtime_end, total_sleep_duration, data, synced_at)
                   VALUES (%s, %s, %s, %s, %s, %s, now())
                   ON CONFLICT (id) DO UPDATE
                   SET day = excluded.day, bedtime_start = excluded.bedtime_start,
                       bedtime_end = excluded.bedtime_end,
                       total_sleep_duration = excluded.total_sleep_duration,
                       data = excluded.data, synced_at = now()""",
                (
                    rec["id"], rec["day"], rec.get("bedtime_start"), rec.get("bedtime_end"),
                    rec.get("total_sleep_duration"), json.dumps(rec),
                ),
            )
            count += 1
    conn.commit()
    return count


def sync_daily_spo2(conn, session, start_date, end_date):
    count = 0
    with conn.cursor() as cur:
        for rec in fetch_paginated(session, "daily_spo2", start_date, end_date):
            spo2 = (rec.get("spo2_percentage") or {}).get("average")
            cur.execute(
                """INSERT INTO oura.daily_spo2 (id, day, spo2_percentage, data, synced_at)
                   VALUES (%s, %s, %s, %s, now())
                   ON CONFLICT (id) DO UPDATE
                   SET day = excluded.day, spo2_percentage = excluded.spo2_percentage,
                       data = excluded.data, synced_at = now()""",
                (rec["id"], rec["day"], spo2, json.dumps(rec)),
            )
            count += 1
    conn.commit()
    return count


def sync_daily_stress(conn, session, start_date, end_date):
    count = 0
    with conn.cursor() as cur:
        for rec in fetch_paginated(session, "daily_stress", start_date, end_date):
            cur.execute(
                """INSERT INTO oura.daily_stress (day, data, synced_at)
                   VALUES (%s, %s, now())
                   ON CONFLICT (day) DO UPDATE
                   SET data = excluded.data, synced_at = now()""",
                (rec["day"], json.dumps(rec)),
            )
            count += 1
    conn.commit()
    return count


def sync_heart_rate(conn, session, start_date, end_date):
    count = 0
    with conn.cursor() as cur:
        for rec in fetch_paginated(session, "heartrate", start_date, end_date):
            cur.execute(
                """INSERT INTO oura.heart_rate ("timestamp", source, bpm, synced_at)
                   VALUES (%s, %s, %s, now())
                   ON CONFLICT ("timestamp", source) DO UPDATE
                   SET bpm = excluded.bpm, synced_at = now()""",
                (rec["timestamp"], rec["source"], rec["bpm"]),
            )
            count += 1
    conn.commit()
    return count


def sync_activity_events(conn, session, endpoint, table, column, api_field, start_date, end_date,
                          has_calories=False):
    """Endpoints shaped like {id, day, start_datetime, end_datetime, ...}:
    workout, session."""
    calories_col = ", calories" if has_calories else ""
    calories_val = ", %s" if has_calories else ""
    calories_upd = ", calories = excluded.calories" if has_calories else ""
    count = 0
    with conn.cursor() as cur:
        for rec in fetch_paginated(session, endpoint, start_date, end_date):
            params = [
                rec["id"], rec["day"], rec.get(api_field),
                rec.get("start_datetime"), rec.get("end_datetime"), json.dumps(rec),
            ]
            if has_calories:
                params.append(rec.get("calories"))
            cur.execute(
                f"""INSERT INTO oura.{table}
                        (id, day, {column}, start_datetime, end_datetime, data{calories_col}, synced_at)
                    VALUES (%s, %s, %s, %s, %s, %s{calories_val}, now())
                    ON CONFLICT (id) DO UPDATE
                    SET day = excluded.day, {column} = excluded.{column},
                        start_datetime = excluded.start_datetime,
                        end_datetime = excluded.end_datetime,
                        data = excluded.data{calories_upd}, synced_at = now()""",
                params,
            )
            count += 1
    conn.commit()
    return count


def sync_tags(conn, session, start_date, end_date):
    """enhanced_tag records use start_day/end_day, not day like the other
    endpoints (a tag can span multiple days)."""
    count = 0
    with conn.cursor() as cur:
        for rec in fetch_paginated(session, "enhanced_tag", start_date, end_date):
            cur.execute(
                """INSERT INTO oura.tags (id, start_day, end_day, data, synced_at)
                   VALUES (%s, %s, %s, %s, now())
                   ON CONFLICT (id) DO UPDATE
                   SET start_day = excluded.start_day, end_day = excluded.end_day,
                       data = excluded.data, synced_at = now()""",
                (rec["id"], rec["start_day"], rec.get("end_day"), json.dumps(rec)),
            )
            count += 1
    conn.commit()
    return count


SIMPLE_ENDPOINTS = [
    ("daily_activity", "daily_activity"),
    ("daily_sleep", "daily_sleep"),
    ("daily_readiness", "daily_readiness"),
]


def main():
    load_env()
    token = os.environ.get("OURA_ACCESS_TOKEN", "").strip()
    db_url = os.environ.get("OURA_DATABASE_URL", "").strip()

    if not token:
        print("OURA_ACCESS_TOKEN is not set in oura/.env — get one at "
              "https://cloud.ouraring.com/personal-access-tokens and add it, "
              "then re-run. Nothing was synced.", file=sys.stderr)
        sys.exit(1)
    if not db_url:
        print("OURA_DATABASE_URL is not set in oura/.env.", file=sys.stderr)
        sys.exit(1)

    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {token}"
    conn = psycopg.connect(db_url)

    end_date = date.today()
    jobs = []
    for endpoint, table in SIMPLE_ENDPOINTS:
        jobs.append((endpoint, lambda s, sd, ed, endpoint=endpoint, table=table:
                      sync_day_scored(conn, s, endpoint, table, sd, ed)))
    jobs.append(("sleep", lambda s, sd, ed: sync_sleep_periods(conn, s, sd, ed)))
    jobs.append(("daily_spo2", lambda s, sd, ed: sync_daily_spo2(conn, s, sd, ed)))
    jobs.append(("daily_stress", lambda s, sd, ed: sync_daily_stress(conn, s, sd, ed)))
    jobs.append(("heartrate", lambda s, sd, ed: sync_heart_rate(conn, s, sd, ed)))
    jobs.append(("enhanced_tag", lambda s, sd, ed: sync_tags(conn, s, sd, ed)))
    jobs.append(("workout", lambda s, sd, ed:
                 sync_activity_events(conn, s, "workout", "workouts", "activity", "activity", sd, ed,
                                       has_calories=True)))
    jobs.append(("session", lambda s, sd, ed:
                 sync_activity_events(conn, s, "session", "sessions", "session_type", "type", sd, ed)))

    had_failure = False
    for endpoint, run in jobs:
        start_date = last_window_end(conn, endpoint)
        if start_date >= end_date:
            print(f"[{endpoint}] up to date, skipping")
            continue
        log_id = start_sync_log(conn, endpoint, start_date, end_date)
        try:
            n = run(session, start_date, end_date)
            finish_sync_log(conn, log_id, "success", n)
            print(f"[{endpoint}] synced {n} records ({start_date} .. {end_date})")
        except Exception as exc:  # noqa: BLE001 — log and continue with other endpoints
            conn.rollback()
            finish_sync_log(conn, log_id, "failed", 0, error=str(exc))
            print(f"[{endpoint}] FAILED: {exc}", file=sys.stderr)
            had_failure = True

    conn.close()
    sys.exit(1 if had_failure else 0)


if __name__ == "__main__":
    main()
