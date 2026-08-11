#!/usr/bin/env python3
"""Mirror selected Home Assistant long-term statistics into Postgres.

Phase 4 scope: snapshot backfill and reconciliation.

    python3 ha_sync.py backfill      # import all history for allowlisted metrics
    python3 ha_sync.py reconcile     # verify the mirror against the source

Reads Home Assistant's recorder database READ-ONLY. Never writes to it.

Key decisions, and why:

* The backfill reads a SNAPSHOT, not the live database. On WAL an open read
  transaction does not block writers but does prevent checkpointing, so holding
  one for the minutes a full backfill takes would grow the WAL without bound on
  a Raspberry Pi. sqlite3's backup API produces a consistent copy including the
  WAL and releases the source immediately.

* Reconciliation compares against that SAME snapshot. The live database keeps
  changing, so comparing against it would report spurious mismatches forever.

* Grain is resolved from reviewed configuration, never inferred from the
  spacing between observations. A timestamp that matches no configured range is
  a hard error, not a default.

* Concurrency is a PostgreSQL advisory lock, released by the server when the
  connection dies. A `running` row plus a unique index would survive a SIGKILL
  and block every future run.

* Restartable and idempotent, NOT resumable: there is no checkpoint. A failed
  backfill is re-run from the start, which the conditional upsert makes cheap.
"""
from __future__ import annotations

import argparse
import math
import os
import shutil
import sqlite3
import sys
import tempfile
import tomllib
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg

EXPORTER_VERSION = "0.1.0"
SCHEMA_VERSION = 1

# Fixed, documented advisory-lock key. Deliberately NOT hashtext('ha_sync'):
# the advisory lock space is global to the database, and a hashed string could
# collide with another application's key.
ADVISORY_LOCK_KEY = 4717001

# A run still marked `running` after this long had its process killed.
STALE_RUN_AFTER = timedelta(hours=6)

HERE = Path(__file__).resolve().parent

# Columns this exporter depends on. Asserted at startup so a Home Assistant
# upgrade that renames one fails loudly here instead of silently writing NULLs.
REQUIRED_STATISTICS_COLUMNS = {
    "metadata_id", "start_ts", "mean", "mean_weight", "min", "max",
    "state", "sum", "last_reset_ts",
}
REQUIRED_META_COLUMNS = {"id", "statistic_id"}

FACT_COLUMNS = [
    "statistic_id", "start_at", "grain", "mean", "mean_weight",
    "min", "max", "state", "sum", "last_reset_at",
]

# Columns compared to decide whether a row actually changed. `synced_at` is
# excluded on purpose: including it would rewrite every overlapping row on
# every run and make "a second run changes nothing" impossible to assert.
COMPARED = ["grain", "mean", "mean_weight", "min", "max", "state", "sum",
            "last_reset_at"]


# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------
def load_env() -> None:
    env = HERE / ".env"
    if not env.exists():
        sys.exit(f"error: {env} not found (copy .env.example and fill it in)")
    for line in env.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())


def load_config() -> dict:
    return tomllib.loads((HERE / "ha_metrics.toml").read_text())


def parse_ts(value) -> datetime | None:
    """TOML gives us either a datetime, the string '-infinity', or false."""
    if value is False or value is None:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if isinstance(value, str):
        if value == "-infinity":
            return datetime.min.replace(tzinfo=timezone.utc)
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    raise ValueError(f"unparseable timestamp: {value!r}")


class GrainResolver:
    """Resolves a row's grain from reviewed configuration.

    Half-open intervals: [valid_from, valid_until). Metrics with no configured
    periods use their catalog default_grain.
    """

    def __init__(self, config: dict):
        self.default = {m["statistic_id"]: m.get("default_grain", "hour")
                        for m in config["metric"]}
        self.periods: dict[str, list[tuple]] = {}
        for p in config.get("grain_period", []):
            self.periods.setdefault(p["statistic_id"], []).append(
                (parse_ts(p["valid_from"]), parse_ts(p.get("valid_until")),
                 p["grain"]))
        for sid in self.periods:
            self.periods[sid].sort(key=lambda t: t[0])

    def resolve(self, statistic_id: str, start_at: datetime) -> str:
        ranges = self.periods.get(statistic_id)
        if not ranges:
            return self.default[statistic_id]
        for lo, hi, grain in ranges:
            if lo <= start_at and (hi is None or start_at < hi):
                return grain
        # Never default. An unreviewed timestamp means configuration is stale.
        raise SystemExit(
            f"error: {statistic_id} has a row at {start_at.isoformat()} that "
            f"matches no configured grain period. Update ha_metrics.toml, "
            f"re-run gen_seed.py, then use `repair` for the affected range.")


# --------------------------------------------------------------------------
# SQLite source
# --------------------------------------------------------------------------
def open_source(db_path: Path) -> sqlite3.Connection:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=60)
    con.execute("PRAGMA busy_timeout = 30000")
    con.execute("PRAGMA query_only = 1")
    return con


def assert_source_schema(con: sqlite3.Connection) -> None:
    for table, required in (("statistics", REQUIRED_STATISTICS_COLUMNS),
                            ("statistics_meta", REQUIRED_META_COLUMNS)):
        present = {r[1] for r in con.execute(f"PRAGMA table_info({table})")}
        if not present:
            sys.exit(f"error: table `{table}` not found in the recorder database")
        missing = required - present
        if missing:
            sys.exit(
                f"error: `{table}` is missing expected column(s): "
                f"{sorted(missing)}. Home Assistant's schema has changed; "
                f"ha_sync must be updated before it can run safely.")


@contextmanager
def snapshot(db_path: Path):
    """A consistent copy of the recorder database, WAL included.

    Created inside a 0700 directory with the file itself 0600, and removed in
    `finally` -- it is a complete copy of household telemetry.
    """
    tmpdir = Path(tempfile.mkdtemp(prefix="ha_sync_snap_"))  # mkdtemp is 0700
    snap_path = tmpdir / "snapshot.db"
    src = open_source(db_path)
    try:
        dst = sqlite3.connect(snap_path)
        try:
            src.backup(dst)
        finally:
            dst.close()
        os.chmod(snap_path, 0o600)
        yield snap_path
    finally:
        src.close()
        shutil.rmtree(tmpdir, ignore_errors=True)


def ha_version(config_dir: Path) -> str | None:
    f = config_dir / ".HA_VERSION"
    try:
        return f.read_text().strip()
    except OSError:
        return None


def fetch_rows(sq: sqlite3.Connection, statistic_id: str,
               since: datetime | None = None, until: datetime | None = None):
    sql = ["""SELECT s.start_ts, s.mean, s.mean_weight, s.min, s.max,
                     s.state, s.sum, s.last_reset_ts
              FROM statistics s
              JOIN statistics_meta m ON s.metadata_id = m.id
              WHERE m.statistic_id = ?"""]
    params: list = [statistic_id]
    if since is not None:
        sql.append("AND s.start_ts >= ?")
        params.append(since.timestamp())
    if until is not None:
        sql.append("AND s.start_ts < ?")
        params.append(until.timestamp())
    sql.append("ORDER BY s.start_ts")
    return sq.execute(" ".join(sql), params).fetchall()


@contextmanager
def live_read(db_path: Path):
    """A short deferred read transaction against the LIVE recorder database.

    Used by incremental and repair, where the read is seconds rather than
    minutes. One BEGIN DEFERRED gives a single consistent view for the whole
    read; on WAL it does not block Home Assistant's writes. Backfill uses a
    snapshot instead, because holding a read transaction open for minutes would
    prevent WAL checkpointing and grow the WAL without bound on a Pi.
    """
    con = open_source(db_path)
    try:
        con.execute("BEGIN DEFERRED")
        assert_source_schema(con)
        yield con
        con.execute("COMMIT")
    finally:
        con.close()


def to_utc(ts: float | None) -> datetime | None:
    return None if ts is None else datetime.fromtimestamp(ts, tz=timezone.utc)


# --------------------------------------------------------------------------
# Postgres side
# --------------------------------------------------------------------------
def acquire_lock(pg: psycopg.Connection) -> bool:
    with pg.cursor() as cur:
        cur.execute("SELECT pg_try_advisory_lock(%s)", (ADVISORY_LOCK_KEY,))
        return cur.fetchone()[0]


def reap_stale_runs(pg: psycopg.Connection) -> int:
    """Mark abandoned runs. Only safe once the advisory lock is HELD --
    otherwise this could mark a genuinely active run as abandoned."""
    with pg.cursor() as cur:
        cur.execute(
            """UPDATE homeassistant.sync_run
                  SET status = 'abandoned',
                      error = coalesce(error, 'process died; reaped at startup')
                WHERE status = 'running' AND started_at < %s""",
            (datetime.now(timezone.utc) - STALE_RUN_AFTER,))
        return cur.rowcount


def start_run(pg, mode, window_start, window_end, hav) -> int:
    with pg.cursor() as cur:
        cur.execute(
            """INSERT INTO homeassistant.sync_run
                   (mode, window_start, window_end, exporter_version,
                    schema_version, ha_version)
               VALUES (%s, %s, %s, %s, %s, %s) RETURNING id""",
            (mode, window_start, window_end, EXPORTER_VERSION,
             SCHEMA_VERSION, hav))
        return cur.fetchone()[0]


def finish_run(pg, run_id, status, stats=None, error=None, source_max=None):
    s = stats or {}
    with pg.cursor() as cur:
        cur.execute(
            """UPDATE homeassistant.sync_run
                  SET finished_at = now(), status = %s, error = %s,
                      rows_read = %s, rows_inserted = %s, rows_updated = %s,
                      rows_unchanged = %s, source_max_ts = %s
                WHERE id = %s""",
            (status, error, s.get("read"), s.get("inserted"), s.get("updated"),
             s.get("unchanged"), source_max, run_id))
    pg.commit()


UPSERT = f"""
INSERT INTO homeassistant.statistic AS t ({', '.join(FACT_COLUMNS)})
SELECT {', '.join(FACT_COLUMNS)} FROM _incoming
ON CONFLICT (statistic_id, start_at) DO UPDATE SET
    {', '.join(f'{c} = EXCLUDED.{c}' for c in COMPARED)},
    synced_at = now()
WHERE ({', '.join('t.' + c for c in COMPARED)})
   IS DISTINCT FROM
      ({', '.join('EXCLUDED.' + c for c in COMPARED)})
RETURNING (xmax = 0) AS inserted
"""


def upsert_metric(pg, statistic_id, rows, resolver) -> dict:
    """Load one metric's rows in its own transaction.

    COPY into a temp table then a single set-based upsert: on a Pi this is far
    faster than per-row executemany, and `xmax = 0` distinguishes inserts from
    updates so the counters mean something.
    """
    payload = []
    for start_ts, mean, mean_weight, mn, mx, state, ssum, last_reset in rows:
        start_at = to_utc(start_ts)
        payload.append((statistic_id, start_at,
                        resolver.resolve(statistic_id, start_at),
                        mean, mean_weight, mn, mx, state, ssum,
                        to_utc(last_reset)))

    with pg.cursor() as cur:
        cur.execute("""CREATE TEMP TABLE _incoming
                       (LIKE homeassistant.statistic INCLUDING DEFAULTS)
                       ON COMMIT DROP""")
        with cur.copy(f"COPY _incoming ({', '.join(FACT_COLUMNS)}) "
                      f"FROM STDIN") as cp:
            for rec in payload:
                cp.write_row(rec)
        cur.execute(UPSERT)
        results = cur.fetchall()
        # Recorded in the SAME transaction as the rows it describes, so the
        # watermark can never claim coverage that was rolled back.
        cur.execute(
            """INSERT INTO homeassistant.metric_watermark
                   (statistic_id, source_max_ts, observed_at)
               VALUES (%s, %s, now())
               ON CONFLICT (statistic_id) DO UPDATE
                   SET source_max_ts = GREATEST(
                           homeassistant.metric_watermark.source_max_ts,
                           EXCLUDED.source_max_ts),
                       observed_at = now()""",
            (statistic_id, max(p[1] for p in payload)))
    pg.commit()

    inserted = sum(1 for (ins,) in results if ins)
    return {"read": len(payload), "inserted": inserted,
            "updated": len(results) - inserted,
            "unchanged": len(payload) - len(results)}


# --------------------------------------------------------------------------
# reconciliation
# --------------------------------------------------------------------------
def values_equal(a, b, tol=1e-9) -> bool:
    """NULL-aware, NaN-aware, tolerance-aware float comparison.

    Plain `=` is wrong three ways here: NULL never equals NULL, NaN never
    equals NaN, and float round-tripping can differ in the last bit.
    """
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, float) and isinstance(b, float):
        if math.isnan(a) or math.isnan(b):
            return math.isnan(a) and math.isnan(b)
        if math.isinf(a) or math.isinf(b):
            return a == b
        return math.isclose(a, b, rel_tol=tol, abs_tol=tol)
    return a == b


COMPARED_FIELDS = ["mean", "mean_weight", "min", "max", "state", "sum"]


def metric_watermarks(pg) -> dict:
    """Newest source timestamp a successful run actually observed, per metric.

    Per-metric rather than global: a global maximum assumes every statistic
    advances together within a Home Assistant compile pass, and a metric that
    lagged would have its later rows compared against a mirror that never had
    the chance to import them.
    """
    with pg.cursor() as cur:
        cur.execute("""SELECT statistic_id, source_max_ts
                       FROM homeassistant.metric_watermark""")
        return dict(cur.fetchall())


def reconcile(pg, sq, statistic_ids, resolver, max_problems=200,
              watermarks: dict | None = None) -> list[str]:
    """EXHAUSTIVE, grain-aware comparison of mirror against source.

    Every row is compared, not a sample. An earlier version checked row count,
    timestamp bounds, and 25 random rows per metric -- which for 188k rows left
    almost every value unverified, let a corrupted row still report "clean",
    and made repeated runs disagree with each other because the sample was
    random. Counts and bounds cannot detect a wrong VALUE at a right timestamp.

    Both sides are streamed in start_at order and merge-walked, so memory stays
    flat regardless of history size -- no need to materialise either side.

    `grain` is compared too, recomputed from configuration. It is a stored
    column that every reporting view depends on, so a row filed under the wrong
    grain corrupts all downstream output while every HA-sourced value matches.

    `synced_at` is excluded deliberately: it is mirror bookkeeping, not a
    source field.
    """
    problems: list[str] = []

    def note(msg: str) -> bool:
        problems.append(msg)
        return len(problems) >= max_problems

    for sid in statistic_ids:
        # Bound BOTH streams identically. Filtering only the source left
        # destination rows above the bound in the walk, so a partial run that
        # committed valid rows past the watermark had them reported as
        # "ABSENT from source" -- the comparison domains have to match.
        bound = (watermarks or {}).get(sid)

        src_cur = sq.execute(
            """SELECT s.start_ts, s.mean, s.mean_weight, s.min, s.max,
                      s.state, s.sum, s.last_reset_ts
               FROM statistics s
               JOIN statistics_meta m ON s.metadata_id = m.id
               WHERE m.statistic_id = ?
                 AND (? IS NULL OR s.start_ts <= ?)
               ORDER BY s.start_ts""",
            (sid, bound.timestamp() if bound else None,
             bound.timestamp() if bound else None))

        # Server-side cursor: streams instead of buffering the whole metric.
        with pg.cursor(name=f"recon_{abs(hash(sid))}") as dst_cur:
            dst_cur.itersize = 5000
            dst_cur.execute(
                """SELECT start_at, grain, mean, mean_weight, min, max,
                          state, sum, last_reset_at
                   FROM homeassistant.statistic
                   WHERE statistic_id = %s
                     AND (%s::timestamptz IS NULL OR start_at <= %s)
                   ORDER BY start_at""", (sid, bound, bound))

            src_it, dst_it = iter(src_cur), iter(dst_cur)
            s = next(src_it, None)
            d = next(dst_it, None)

            while s is not None or d is not None:
                s_ts = to_utc(s[0]) if s is not None else None
                d_ts = d[0] if d is not None else None

                if d_ts is None or (s_ts is not None and s_ts < d_ts):
                    if note(f"{sid} @ {s_ts}: in source, MISSING from mirror"):
                        return problems
                    s = next(src_it, None)
                    continue
                if s_ts is None or d_ts < s_ts:
                    if note(f"{sid} @ {d_ts}: in mirror, ABSENT from source"):
                        return problems
                    d = next(dst_it, None)
                    continue

                expected_grain = resolver.resolve(sid, s_ts)
                if d[1] != expected_grain:
                    if note(f"{sid} @ {s_ts}: grain source={expected_grain!r} "
                            f"mirror={d[1]!r}"):
                        return problems

                for name, a, b in zip(COMPARED_FIELDS, s[1:7], d[2:8]):
                    if not values_equal(a, b):
                        if note(f"{sid} @ {s_ts}: {name} "
                                f"source={a!r} mirror={b!r}"):
                            return problems

                if not values_equal(to_utc(s[7]), d[8]):
                    if note(f"{sid} @ {s_ts}: last_reset_at "
                            f"source={to_utc(s[7])!r} mirror={d[8]!r}"):
                        return problems

                s = next(src_it, None)
                d = next(dst_it, None)
        pg.rollback()   # close the server-side cursor's transaction cleanly

    return problems


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------
def assert_catalog_matches_config(pg, config) -> None:
    """The TOML and the seeded catalog must describe exactly the same set.

    They are two copies of one contract, and drift between them fails in ways
    that are hard to read: a metric in TOML but not the catalog is silently
    skipped (membership is read from Postgres), while one in the catalog but
    not TOML reaches GrainResolver with no default and dies on a bare KeyError.
    Fail here instead, naming both sides.
    """
    toml_ids = {m["statistic_id"] for m in config["metric"]}
    with pg.cursor() as cur:
        cur.execute("SELECT statistic_id FROM homeassistant.metric_catalog")
        catalog_ids = {r[0] for r in cur.fetchall()}

    only_toml = sorted(toml_ids - catalog_ids)
    only_catalog = sorted(catalog_ids - toml_ids)
    if only_toml or only_catalog:
        lines = ["error: ha_metrics.toml and metric_catalog disagree."]
        if only_toml:
            lines.append(f"  in TOML but not the catalog ({len(only_toml)}) -- "
                         f"re-run gen_seed.py and apply seed_catalog.sql:")
            lines += [f"    {s}" for s in only_toml[:10]]
        if only_catalog:
            lines.append(f"  in the catalog but not TOML ({len(only_catalog)}) -- "
                         f"a metric was removed from the allowlist without "
                         f"removing it from the catalog:")
            lines += [f"    {s}" for s in only_catalog[:10]]
        sys.exit("\n".join(lines))


def selected_metrics(pg, config) -> list[str]:
    """Catalog membership is the contract; grain_review_required halts export."""
    with pg.cursor() as cur:
        cur.execute("""SELECT statistic_id FROM homeassistant.metric_catalog
                       WHERE NOT grain_review_required ORDER BY statistic_id""")
        return [r[0] for r in cur.fetchall()]


def cmd_backfill(args, pg, config, db_path, cfg_dir):
    resolver = GrainResolver(config)
    wanted = selected_metrics(pg, config)
    hav = ha_version(cfg_dir)
    run_id = start_run(pg, "backfill", None, None, hav)
    totals = {"read": 0, "inserted": 0, "updated": 0, "unchanged": 0}
    source_max = None
    try:
        with snapshot(db_path) as snap:
            sq = open_source(snap)
            assert_source_schema(sq)
            available = {r[0] for r in sq.execute(
                "SELECT statistic_id FROM statistics_meta")}
            missing = [s for s in wanted if s not in available]
            if missing:
                print(f"  note: {len(missing)} allowlisted metric(s) absent "
                      f"from HA, skipped: {missing[:3]}"
                      f"{'...' if len(missing) > 3 else ''}")
            todo = [s for s in wanted if s in available]

            for i, sid in enumerate(todo, 1):
                rows = fetch_rows(sq, sid)
                if not rows:
                    continue
                st = upsert_metric(pg, sid, rows, resolver)
                for k in totals:
                    totals[k] += st[k]
                latest = to_utc(rows[-1][0])
                source_max = latest if source_max is None else max(source_max, latest)
                print(f"  [{i:>3}/{len(todo)}] {sid:<58} "
                      f"read={st['read']:>6} ins={st['inserted']:>6} "
                      f"upd={st['updated']:>5} same={st['unchanged']:>6}")

            print("\n  reconciling against the snapshot...")
            problems = reconcile(pg, sq, todo, resolver)
            sq.close()
    except SystemExit as exc:
        # Reached by the source-schema assertion and by grain resolution, which
        # both run inside the run. Record what actually happened; labelling them
        # all "grain resolution failed" made sync_run.error misleading.
        #
        # NOT reached by catalog/TOML drift: that is a precondition checked in
        # main() before any run row exists, so it fails loudly on stderr with a
        # nonzero exit and never appears in sync_run. That is deliberate -- a
        # configuration mismatch is not a sync attempt worth recording -- but it
        # does mean drift is visible only to whatever watches the exit code.
        finish_run(pg, run_id, "failed", totals,
                   str(exc) or "SystemExit with no message", source_max)
        raise
    except Exception as exc:
        pg.rollback()
        finish_run(pg, run_id, "failed", totals, f"{type(exc).__name__}: {exc}",
                   source_max)
        raise

    if problems:
        finish_run(pg, run_id, "failed", totals,
                   f"reconciliation: {len(problems)} problem(s)", source_max)
        print(f"\n  RECONCILIATION FAILED - {len(problems)} problem(s):")
        for p in problems[:20]:
            print(f"    - {p}")
        return 1

    finish_run(pg, run_id, "success", totals, None, source_max)
    print(f"\n  reconciled clean: {totals['read']} rows across {len(todo)} metrics")
    print(f"  inserted={totals['inserted']} updated={totals['updated']} "
          f"unchanged={totals['unchanged']}")
    return 0


# --------------------------------------------------------------------------
# cadence audit
# --------------------------------------------------------------------------
# Cadences an interval can be recognised as. An interval counts as a cadence
# when it lands within half..double that cadence, which is wide on purpose:
# a source reporting daily in LOCAL time produces 23h and 25h intervals in UTC
# across DST transitions, and both must still read as "daily".
CANDIDATE_CADENCES = {"hour": timedelta(hours=1), "day": timedelta(days=1)}


def nearest_cadence(gap: timedelta) -> str | None:
    """Which configured cadence does this interval look like, if any?

    Exact equality between two intervals is the wrong test -- it fails on any
    source jitter, and fails outright across DST where a local-daily source
    yields 23h then 25h. Instead each interval is mapped to its nearest
    candidate on a log scale, and two intervals "agree" when they map to the
    same one. An outage gap maps to nothing, so it can never look like a
    cadence change.
    """
    best, best_distance = None, None
    for name, step in CANDIDATE_CADENCES.items():
        ratio = gap / step
        if 0.5 <= ratio <= 2.0:
            distance = abs(math.log(ratio))
            if best_distance is None or distance < best_distance:
                best, best_distance = name, distance
    return best


def cadence_decision(pg, statistic_id, resolver,
                     incoming: list[datetime]) -> tuple[str, datetime | None, str | None]:
    """Decide what to do with a metric's incoming rows: import, hold, or halt.

    Returns (action, hold_from, message) where action is one of
    'import_all' | 'hold_tail' | 'halt'.

    WHY HOLDING IS NECESSARY. An earlier version only halted, and only once two
    agreeing intervals were visible. That is fine when a source resumes in a
    batch, but not when rows arrive one per run:

        run 1: outage interval only            -> no verdict, row imported
        run 2: outage + one 24h interval       -> no agreement, row imported
        run 3: two 24h intervals               -> halt fires, but runs 1 and 2
                                                  already stored rows as `hour`

    Detection came after the corruption it was meant to prevent. So instead of
    importing while evidence accumulates, rows after an unrecognisable interval
    (an outage) are HELD until their cadence is established. The 72-hour overlap
    means held rows are reconsidered on every subsequent run, so a resumption at
    the expected cadence costs a delay of a couple of runs and nothing else.

    Outcomes after an outage:
        fewer than 2 intervals among the new rows  -> hold_tail (not yet known)
        2 agreeing intervals matching the grain    -> import_all
        2 agreeing intervals contradicting it      -> halt
    """
    ranges = resolver.periods.get(statistic_id)
    if not ranges:
        return ("import_all", None, None)
    last_from, last_until, grain = ranges[-1]
    if last_until is not None or grain not in CANDIDATE_CADENCES:
        return ("import_all", None, None)

    with pg.cursor() as cur:
        cur.execute(
            """SELECT start_at FROM homeassistant.statistic
               WHERE statistic_id = %s AND start_at >= %s
               ORDER BY start_at DESC LIMIT 4""", (statistic_id, last_from))
        stored_tail = [r[0] for r in cur.fetchall()]

    stamps = sorted(set(stored_tail) | {t for t in incoming if t >= last_from})
    if len(stamps) < 2:
        return ("import_all", None, None)

    gaps = [b - a for a, b in zip(stamps, stamps[1:])]
    cadences = [nearest_cadence(g) for g in gaps]

    # An interval matching no candidate is an outage boundary. Everything after
    # the LAST such boundary is of unestablished cadence.
    outage_at = None
    for i, c in enumerate(cadences):
        if c is None:
            outage_at = i

    if outage_at is None:
        # No outage in view: judge on the last two intervals as before.
        if len(gaps) >= 2 and cadences[-1] is not None \
                and cadences[-1] == cadences[-2] != grain:
            return ("halt", None,
                    f"configured grain={grain} but the last two intervals "
                    f"({gaps[-2]}, {gaps[-1]}) both read as {cadences[-1]}")
        return ("import_all", None, None)

    post_cadences = cadences[outage_at + 1:]
    post_gaps = gaps[outage_at + 1:]
    boundary = stamps[outage_at + 1]        # first observation after the outage

    if len(post_cadences) >= 2 and post_cadences[-1] is not None \
            and post_cadences[-1] == post_cadences[-2]:
        if post_cadences[-1] == grain:
            return ("import_all", None, None)
        return ("halt", None,
                f"configured grain={grain} but the two intervals after the "
                f"outage ({post_gaps[-2]}, {post_gaps[-1]}) both read as "
                f"{post_cadences[-1]}")

    return ("hold_tail", boundary,
            f"cadence after the outage at {boundary.isoformat()} is not yet "
            f"established ({len(post_gaps)} interval(s) seen); holding "
            f"{len(post_gaps) + 1} row(s) until it is")


def halt_metric(pg, statistic_id: str) -> None:
    """Stop exporting a metric until a human updates the reviewed ranges."""
    with pg.cursor() as cur:
        cur.execute(
            """UPDATE homeassistant.metric_catalog
                  SET grain_review_required = true
                WHERE statistic_id = %s""", (statistic_id,))
    pg.commit()


# --------------------------------------------------------------------------
def _sync_window(args, pg, config, db_path, cfg_dir, mode, since, until):
    """Shared body for incremental and repair: read a window, upsert, audit."""
    resolver = GrainResolver(config)
    wanted = selected_metrics(pg, config)
    run_id = start_run(pg, mode, since, until, ha_version(cfg_dir))
    totals = {"read": 0, "inserted": 0, "updated": 0, "unchanged": 0}
    source_max = None
    halted: list[str] = []
    held: list[str] = []
    try:
        with live_read(db_path) as sq:
            available = {r[0] for r in sq.execute(
                "SELECT statistic_id FROM statistics_meta")}
            todo = [s for s in wanted if s in available]
            for sid in todo:
                rows = fetch_rows(sq, sid, since, until)
                if not rows:
                    continue

                # Gate the import on cadence, judged from SOURCE timestamps
                # before a single row is written. Rows whose cadence is not yet
                # established are HELD rather than imported, so a gradual
                # resumption cannot land mislabelled rows while evidence for
                # the change is still accumulating.
                action, hold_from, msg = cadence_decision(
                    pg, sid, resolver, [to_utc(r[0]) for r in rows])
                if action == "halt":
                    halt_metric(pg, sid)
                    halted.append(f"{sid}: {msg}")
                    continue           # nothing imported for this metric
                if action == "hold_tail":
                    rows = [r for r in rows if to_utc(r[0]) < hold_from]
                    held.append(f"{sid}: {msg}")
                    if not rows:
                        continue

                st = upsert_metric(pg, sid, rows, resolver)
                for k in totals:
                    totals[k] += st[k]
                latest = to_utc(rows[-1][0])
                source_max = latest if source_max is None else max(source_max, latest)
    except SystemExit as exc:
        finish_run(pg, run_id, "failed", totals,
                   str(exc) or "SystemExit with no message", source_max)
        raise
    except Exception as exc:
        pg.rollback()
        finish_run(pg, run_id, "failed", totals, f"{type(exc).__name__}: {exc}",
                   source_max)
        raise

    print(f"  {mode}: read={totals['read']} inserted={totals['inserted']} "
          f"updated={totals['updated']} unchanged={totals['unchanged']}")

    for msg in held:
        print(f"  HOLDING (cadence not established): {msg}")

    if halted:
        # A halted metric means the run did NOT do the work it was asked to do
        # and needs a human. Recording success here would leave the condition
        # invisible to anything watching run status or exit codes.
        finish_run(pg, run_id, "failed", totals,
                   "grain review required -- " + "; ".join(halted), source_max)
        for msg in halted:
            print(f"  GRAIN REVIEW REQUIRED, export halted: {msg}")
        print("  -> update ha_metrics.toml, re-run gen_seed.py, apply the seed,")
        print("     clear grain_review_required, then `repair` the affected range.")
        return 1

    finish_run(pg, run_id, "success", totals, None, source_max)
    return 0


def cmd_incremental(args, pg, config, db_path, cfg_dir):
    """Re-read the last OVERLAP_HOURS and upsert.

    Not a high-water mark: Home Assistant revises recent statistics, and the
    statistics-repair UI lets them be corrected by hand. `WHERE start_ts > last`
    would import the first, wrong value and keep it forever.
    """
    until = datetime.now(timezone.utc)
    since = until - timedelta(hours=args.overlap_hours)
    return _sync_window(args, pg, config, db_path, cfg_dir,
                        "incremental", since, None)


def parse_bound(text: str, label: str) -> datetime:
    """Parse a CLI timestamp to UTC.

    Naive input is TREATED as UTC; offset-bearing input is CONVERTED to UTC.
    The earlier `.replace(tzinfo=utc)` did neither -- it relabelled an
    offset-bearing timestamp as UTC, silently shifting the requested window by
    the offset.
    """
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        sys.exit(f"error: --{label} {text!r} is not an ISO date or datetime "
                 f"(expected YYYY-MM-DD or YYYY-MM-DDTHH:MM[+OFFSET])")
    return (dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None
            else dt.astimezone(timezone.utc))


def cmd_repair(args, pg, config, db_path, cfg_dir):
    since = parse_bound(args.since, "from")
    until = parse_bound(args.until, "to") if args.until else None
    # Half-open [since, until). An empty or inverted range is a mistake, not a
    # no-op that should report success over zero rows.
    if until is not None and until <= since:
        sys.exit(f"error: --to ({until.isoformat()}) must be strictly after "
                 f"--from ({since.isoformat()}); the range is half-open "
                 f"[from, to) and would otherwise select nothing")
    print(f"  repairing [{since.isoformat()} .. "
          f"{until.isoformat() if until else 'now'})")
    return _sync_window(args, pg, config, db_path, cfg_dir,
                        "repair", since, until)


def notify_home_assistant(title: str, message: str) -> bool:
    """Best-effort push through Home Assistant, for health alerts.

    The health check exists to catch failures that Postgres cannot record --
    including Postgres being down -- so its alert must not depend on the
    database. Failing to notify is itself reported, never swallowed silently.
    """
    import json
    import urllib.request

    base = os.environ.get("HA_BASE_URL")
    token_file = os.environ.get("HA_TOKEN_FILE")
    if not base or not token_file or not Path(token_file).exists():
        print("  (no HA_BASE_URL / HA_TOKEN_FILE configured; not notifying)")
        return False
    try:
        token = Path(token_file).read_text().strip()
        for path, payload in (
            ("/api/services/persistent_notification/create",
             {"title": title, "message": message,
              "notification_id": "ha_sync_health"}),
            ("/api/services/notify/mobile_app_canarsie",
             {"title": title, "message": message}),
        ):
            req = urllib.request.Request(
                base.rstrip("/") + path,
                data=json.dumps(payload).encode(),
                headers={"Authorization": f"Bearer {token}",
                         "Content-Type": "application/json"},
                method="POST")
            urllib.request.urlopen(req, timeout=15)
        # Logged explicitly: when the cron log is the only record, "alerted"
        # and "silently failed to alert" must not look identical.
        print(f"  alerted Home Assistant ({base})")
        return True
    except Exception as exc:            # noqa: BLE001 - alerting is best effort
        print(f"  WARNING: could not notify Home Assistant: "
              f"{type(exc).__name__}: {exc}")
        return False


def run_health(args, config, db_path, cfg_dir) -> int:
    """Health entry point, deliberately OUTSIDE the Postgres context manager.

    The whole point of this check is to catch failures the pipeline cannot
    record about itself -- and the most important of those is Postgres being
    unreachable. An earlier version ran inside `with psycopg.connect(...)`, so a
    database outage raised before any alerting code was reached and the only
    trace was a line in a redirected cron log that nothing watches.

    Preflight failures (missing recorder database) are treated the same way:
    reported, alerted, nonzero.
    """
    problems = []
    if not db_path.exists():
        problems.append(f"recorder database missing at {db_path}")

    pg = None
    try:
        pg = psycopg.connect(os.environ["HA_EXPORT_DATABASE_URL"],
                             connect_timeout=15)
    except Exception as exc:            # noqa: BLE001 - any failure is unhealthy
        problems.append(f"cannot reach Postgres: {type(exc).__name__}: {exc}")

    if problems:
        summary = "; ".join(problems)
        print(f"  UNHEALTHY: {summary}")
        notify_home_assistant("HA statistics sync unhealthy", summary)
        if pg is not None:
            pg.close()
        return 1

    try:
        return cmd_health(args, pg, config, db_path, cfg_dir)
    finally:
        pg.close()


def cmd_health(args, pg, config, db_path, cfg_dir):
    """Is the pipeline actually running? Exits nonzero when it is not.

    Separate from the sync itself and scheduled separately, because a failure
    that stops the sync from writing to Postgres also stops it from recording
    that failure. Cron redirecting output to a log file does not alert anyone
    by itself, so an unhealthy result is pushed through Home Assistant.
    """
    threshold = timedelta(hours=args.max_age_hours)
    with pg.cursor() as cur:
        # Filtered to `incremental`: a manual backfill or repair would
        # otherwise refresh this timestamp and make a stalled hourly pipeline
        # look healthy.
        cur.execute(
            """SELECT max(finished_at) FROM homeassistant.sync_run
               WHERE status = 'success' AND mode = 'incremental'""")
        last_success = cur.fetchone()[0]
        cur.execute(
            """SELECT max(finished_at) FROM homeassistant.sync_run
               WHERE status = 'success'""")
        any_success = cur.fetchone()[0]
        cur.execute(
            """SELECT count(*) FROM homeassistant.metric_catalog
               WHERE grain_review_required""")
        halted = cur.fetchone()[0]

    problems = []
    if any_success is not None:
        print(f"  last success (any mode): {any_success.isoformat()}")
    if last_success is None:
        problems.append("no successful INCREMENTAL sync has ever completed")
    else:
        age = datetime.now(timezone.utc) - last_success
        print(f"  last incremental success: {last_success.isoformat()} "
              f"({age} ago)")
        if age > threshold:
            problems.append(f"last successful incremental sync was {age} ago "
                            f"(threshold {threshold})")

    if halted:
        problems.append(f"{halted} metric(s) halted awaiting grain review")

    if problems:
        summary = "; ".join(problems)
        print(f"  UNHEALTHY: {summary}")
        notify_home_assistant("HA statistics sync unhealthy", summary)
        return 1
    print("  healthy")
    return 0


def cmd_reconcile(args, pg, config, db_path, cfg_dir):
    wanted = selected_metrics(pg, config)
    with snapshot(db_path) as snap:
        sq = open_source(snap)
        assert_source_schema(sq)
        available = {r[0] for r in sq.execute(
            "SELECT statistic_id FROM statistics_meta")}
        marks = metric_watermarks(pg)
        if marks:
            print(f"  comparing each metric up to its own sync watermark "
                  f"({len(marks)} recorded)")
        problems = reconcile(pg, sq,
                             [s for s in wanted if s in available],
                             GrainResolver(config), watermarks=marks)
        sq.close()
    if problems:
        print(f"  {len(problems)} problem(s):")
        for p in problems[:40]:
            print(f"    - {p}")
        return 1
    print("  reconciled clean")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    sub.add_parser("backfill", help="import all history for allowlisted metrics")
    sub.add_parser("reconcile", help="verify the mirror against the source")
    inc = sub.add_parser("incremental", help="re-read a recent overlap window")
    inc.add_argument("--overlap-hours", type=int, default=72,
                     help="how far back to re-read (default 72)")
    rep = sub.add_parser("repair", help="re-import an arbitrary date range")
    rep.add_argument("--from", dest="since", required=True,
                     metavar="YYYY-MM-DD", help="inclusive start (UTC)")
    rep.add_argument("--to", dest="until", metavar="YYYY-MM-DD",
                     help="exclusive end (UTC); omit for open-ended")
    hl = sub.add_parser("health", help="alert if the pipeline has stalled")
    hl.add_argument("--max-age-hours", type=float, default=3.0,
                    help="stale threshold for the last successful sync")
    args = ap.parse_args()

    load_env()
    config = load_config()
    cfg_dir = Path(os.environ["HA_CONFIG_DIR"])
    db_path = cfg_dir / "home-assistant_v2.db"
    # `health` runs outside the Postgres context so it can alert when the
    # database is the thing that is down, and it never takes the advisory lock
    # -- doing so would make it report healthy only while nothing is running.
    if args.command == "health":
        return run_health(args, config, db_path, cfg_dir)

    if not db_path.exists():
        sys.exit(f"error: recorder database not found at {db_path}")

    with psycopg.connect(os.environ["HA_EXPORT_DATABASE_URL"]) as pg:
        if not acquire_lock(pg):
            # Exit 0: a concurrent run is a normal condition, not a failure.
            # But log it -- a silent no-op is indistinguishable from a cron
            # that never fired.
            print("  already_running: another ha_sync holds the advisory lock")
            return 0
        # Only ever AFTER the lock is held.
        reaped = reap_stale_runs(pg)
        if reaped:
            print(f"  reaped {reaped} abandoned run(s)")
        pg.commit()

        assert_catalog_matches_config(pg, config)

        fn = {"backfill": cmd_backfill, "reconcile": cmd_reconcile,
              "incremental": cmd_incremental, "repair": cmd_repair,
              "health": cmd_health}[args.command]
        return fn(args, pg, config, db_path, cfg_dir)


if __name__ == "__main__":
    sys.exit(main())
