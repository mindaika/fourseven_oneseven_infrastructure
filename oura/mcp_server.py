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
    port.
  - Reached via nginx's oura-mcp.garbanzo.monster block, which is
    INTERNET-FACING, not LAN-restricted. The allowlist that used to be
    there was removed on 2026-07-25 because remote-connector OAuth needs
    the vendor's cloud backend to reach /token directly, and a LAN rule
    silently broke the token exchange (see the comment on that server
    block for the full rationale). Anyone on the internet can reach this
    process; the OAuth gate below is what stops them, so treat it as
    load-bearing rather than as defence in depth.
  - OAuth (see oauth_provider.py) is therefore the *only* thing standing
    between the open internet and this server's tools — a single username
    and password from the environment. It still isn't what enforces
    read-only access (the database grants are), but it is now the outer
    perimeter, not a third redundant layer.
"""
import logging
import os

import psycopg
from psycopg.rows import dict_row
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import Response

from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions
from mcp.server.fastmcp import FastMCP

from oauth_provider import SingleUserOAuthProvider

# Uvicorn only configures its own loggers, leaving this app's modules with no
# handler — so oauth_provider's INFO lines (how many client registrations and
# tokens were restored at boot) would silently vanish, which is exactly the
# diagnostic you want when a connector starts failing to authorize.
logging.basicConfig(level=logging.INFO, format="%(levelname)s:     %(name)s - %(message)s")

DATABASE_URL = os.environ["CLAUDE_READER_DATABASE_URL"]
SERVER_URL = os.environ.get("OURA_MCP_SERVER_URL", "https://oura-mcp.garbanzo.monster")
MCP_USERNAME = os.environ["OURA_MCP_USERNAME"]
MCP_PASSWORD = os.environ["OURA_MCP_PASSWORD"]

oauth_provider = SingleUserOAuthProvider(
    username=MCP_USERNAME,
    password=MCP_PASSWORD,
    auth_callback_url=f"{SERVER_URL}/login",
    server_url=SERVER_URL,
    # Static fallback for clients that don't do dynamic client registration
    # (RFC 7591) themselves — paste these into the connector's "OAuth
    # Client ID" / "Client Secret" fields to skip the /register step
    # entirely. Dynamic registration still works independently for any
    # client that does support it.
    static_client_id=os.environ.get("OURA_MCP_STATIC_CLIENT_ID"),
    static_client_secret=os.environ.get("OURA_MCP_STATIC_CLIENT_SECRET"),
    # Survives restarts. Dynamically-registered clients (ChatGPT/Codex
    # connectors, Claude Desktop) cache their client_id forever and never
    # re-register, so without this a reboot permanently breaks them until
    # the connector is deleted and re-added by hand. Bind-mounted; see
    # compose.yaml.
    state_path=os.environ.get("OURA_MCP_STATE_PATH", "/data/oauth_state.json"),
)

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
    auth_server_provider=oauth_provider,
    auth=AuthSettings(
        issuer_url=SERVER_URL,
        client_registration_options=ClientRegistrationOptions(
            enabled=True,
            valid_scopes=["user"],
            default_scopes=["user"],
        ),
        required_scopes=["user"],
        # Enables RFC 9728 Protected Resource Metadata (/.well-known/oauth-
        # protected-resource/mcp) and the resource_metadata hint on 401
        # WWW-Authenticate headers. Without this, discovery silently fails
        # for clients that start from a cold 401 rather than assuming
        # endpoint locations (confirmed: Claude Desktop needs it, a manual
        # client hitting known paths directly doesn't notice its absence).
        resource_server_url=f"{SERVER_URL}/mcp",
    ),
)


@mcp.custom_route("/login", methods=["GET"])
async def login_page_handler(request: Request) -> Response:
    state = request.query_params.get("state")
    if not state:
        raise HTTPException(400, "Missing state parameter")
    return await oauth_provider.get_login_page(state, error=request.query_params.get("error") == "1")


@mcp.custom_route("/login/callback", methods=["POST"])
async def login_callback_handler(request: Request) -> Response:
    return await oauth_provider.handle_login_callback(request)


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
