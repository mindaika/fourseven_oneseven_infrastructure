"""homelab-api: Home Assistant statistics for the garbanzo.monster dashboard."""
from __future__ import annotations

import os

from flask import Flask, jsonify

from .auth import AuthError
from .db import init_pool
from .limits import BadRequest
from .routes import bp


def create_app() -> Flask:
    app = Flask(__name__)

    for var in ("HA_API_DATABASE_URL", "AUTH0_DOMAIN", "AUTH0_AUDIENCE"):
        if not os.environ.get(var):
            raise RuntimeError(f"{var} is not set")

    init_pool()
    app.register_blueprint(bp)

    @app.errorhandler(BadRequest)
    def _bad_request(exc: BadRequest):
        # Limits are explained, not just refused: a caller who asks for too much
        # is told what to change.
        return jsonify(error="bad_request", detail=exc.message), 400

    @app.errorhandler(AuthError)
    def _auth_error(exc: AuthError):
        return jsonify(error="unauthorized", detail=exc.error), exc.status_code

    @app.errorhandler(500)
    def _server_error(_exc):
        return jsonify(error="internal_error"), 500

    return app
