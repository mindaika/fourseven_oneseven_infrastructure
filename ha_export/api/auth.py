"""Auth0 RS256 bearer-token verification.

Follows the pattern already used by dancetrak/jobify/pixify so there is one
auth story across the site, with two deliberate differences:

* JWKS is CACHED. The existing apps fetch Auth0's key set on every request,
  which adds a round trip to each call and makes every endpoint unavailable
  whenever Auth0 is unreachable. Keys rotate rarely; a TTL cache with a forced
  refresh on unknown `kid` keeps rotation working without the per-request cost.

* No query-parameter token fallback. That exists in dancetrak so `<video>` and
  `<img>` elements can authenticate, which this JSON API never needs -- and
  tokens in query strings land in access logs and browser history.
"""
from __future__ import annotations

import json
import time
from functools import wraps
from os import environ
from typing import Any, Callable
from urllib.request import urlopen

from flask import request
from jose import jwt

JWKS_TTL_SECONDS = 3600
_jwks_cache: dict[str, Any] = {"fetched_at": 0.0, "keys": None}


class AuthError(Exception):
    def __init__(self, error: str, status_code: int):
        self.error = error
        self.status_code = status_code


def _fetch_jwks(force: bool = False) -> dict:
    now = time.time()
    if (not force and _jwks_cache["keys"] is not None
            and now - _jwks_cache["fetched_at"] < JWKS_TTL_SECONDS):
        return _jwks_cache["keys"]
    domain = environ["AUTH0_DOMAIN"]
    with urlopen(f"https://{domain}/.well-known/jwks.json", timeout=10) as r:
        keys = json.loads(r.read())
    _jwks_cache.update(fetched_at=now, keys=keys)
    return keys


def _rsa_key_for(kid: str) -> dict:
    for attempt in (False, True):        # retry once, forcing a refresh
        for key in _fetch_jwks(force=attempt).get("keys", []):
            if key["kid"] == kid:
                return {k: key[k] for k in ("kty", "kid", "use", "n", "e")}
    raise AuthError("Unable to find appropriate signing key", 401)


def get_token() -> str:
    auth = request.headers.get("Authorization")
    if not auth:
        raise AuthError("Authorization header is missing", 401)
    parts = auth.split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise AuthError("Authorization header must be 'Bearer <token>'", 401)
    return parts[1]


def requires_auth(f: Callable) -> Callable:
    @wraps(f)
    def decorated(*args: Any, **kwargs: Any) -> Any:
        token = get_token()
        try:
            header = jwt.get_unverified_header(token)
        except jwt.JWTError:
            raise AuthError("Invalid header; token malformed", 401)

        try:
            payload = jwt.decode(
                token,
                _rsa_key_for(header.get("kid", "")),
                algorithms=["RS256"],
                audience=environ["AUTH0_AUDIENCE"],
                issuer=f"https://{environ['AUTH0_DOMAIN']}/")
        except jwt.ExpiredSignatureError:
            raise AuthError("Token is expired", 401)
        except jwt.JWTClaimsError:
            raise AuthError("Invalid claims (audience or issuer)", 401)
        except AuthError:
            raise
        except Exception as exc:         # noqa: BLE001
            raise AuthError(f"Unable to verify token: {type(exc).__name__}", 401)

        return f(*args, current_user=payload.get("sub"), **kwargs)

    return decorated
