"""Postgres access for the API.

Connects as ha_api_reader, which holds SELECT on the six reporting views and
nothing else -- no ingest tables, no other application's schema. The browser
never sees a database credential; it talks to this service over Auth0.
"""
from __future__ import annotations

import os
from contextlib import contextmanager

from psycopg_pool import ConnectionPool

_pool: ConnectionPool | None = None


def init_pool() -> None:
    global _pool
    if _pool is None:
        _pool = ConnectionPool(
            os.environ["HA_API_DATABASE_URL"],
            min_size=1, max_size=4, timeout=10,
            kwargs={"options": "-c statement_timeout=15000"},
            open=True)


@contextmanager
def get_conn():
    if _pool is None:
        init_pool()
    with _pool.connection() as conn:
        # Read-only by construction at the role level; also declared here so an
        # accidental write fails loudly rather than silently succeeding if the
        # grants are ever widened.
        conn.read_only = True
        yield conn
