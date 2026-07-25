#!/usr/bin/env python3
"""MCP server exposing the `reporting` schema (Oura data) for read-only
analysis by Claude.

Security model (by design, not just convention):
  - Connects as `claude_reader`, a dedicated role that only has SELECT on
    the `reporting` schema of views — enforced at the database level, so
    even a fully compromised or malicious query executed through this
    server cannot write, alter, or reach any other schema (oura, dancetrak,
    website, or public/Vaultwarden). See reporting_schema.sql.
  - The query tool additionally rejects anything that isn't a SELECT/WITH
    statement before it ever reaches Postgres, as a second, redundant
    layer — belt and suspenders on top of the database grants doing the
    actual enforcement.
  - Runs on the Docker network local to the Pi (infra_network), talking to
    Postgres by container name — never touches the LAN-exposed Postgres
    port. Reachable itself only from the local network (see compose.yaml:
    no nginx route, no public domain, no OAuth needed for that reason).
"""
import os
import psycopg
from psycopg.rows import dict_row
from mcp.server.fastmcp import FastMCP

DATABASE_URL = os.environ["CLAUDE_READER_DATABASE_URL"]

mcp = FastMCP(
    "oura-reporting",
    instructions=(
        "Read-only access to Oura Ring health data (sleep, readiness, activity, "
        "stress, SpO2, heart rate, workouts, sessions, tags) via the `reporting` "
        "schema. Start with list_tables, then describe_table before writing "
        "queries — column names are not always what you'd guess."
    ),
    host="0.0.0.0",
    port=8765,
)


def _connect():
    return psycopg.connect(DATABASE_URL, row_factory=dict_row)


@mcp.tool()
def list_tables() -> list[dict]:
    """List every view available in the reporting schema, with a short
    description of what each one covers."""
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT table_name FROM information_schema.views "
            "WHERE table_schema = 'reporting' ORDER BY table_name"
        )
        return [dict(row) for row in cur.fetchall()]


@mcp.tool()
def describe_table(table_name: str) -> list[dict]:
    """Get column names and types for a reporting view, so you know what's
    queryable before writing SQL against it."""
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT column_name, data_type FROM information_schema.columns "
            "WHERE table_schema = 'reporting' AND table_name = %s "
            "ORDER BY ordinal_position",
            (table_name,),
        )
        rows = cur.fetchall()
        if not rows:
            raise ValueError(
                f"No such table 'reporting.{table_name}'. Call list_tables() "
                "to see what's available."
            )
        return [dict(row) for row in rows]


@mcp.tool()
def query(sql: str, row_limit: int = 500) -> list[dict]:
    """Run a read-only SQL query against the reporting schema (views only —
    daily_sleep, daily_readiness, daily_activity, sleep_periods, daily_stress,
    daily_spo2, workouts, sessions, tags, heart_rate, sync_status, each
    prefixed reporting.oura_*). Only SELECT/WITH statements are accepted;
    everything else is rejected before it reaches the database. Results are
    capped at row_limit (default 500) to avoid dumping huge result sets."""
    stripped = sql.strip().lstrip("(").strip().upper()
    if not (stripped.startswith("SELECT") or stripped.startswith("WITH")):
        raise ValueError("Only SELECT/WITH (read-only) statements are allowed.")
    row_limit = max(1, min(row_limit, 5000))
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT * FROM ({sql}) AS _q LIMIT %s", (row_limit,))
        return [dict(row) for row in cur.fetchall()]


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
