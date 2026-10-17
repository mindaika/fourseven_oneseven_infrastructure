#!/usr/bin/env bash
# Twice-daily Oura Ring data sync (see crontab).
# Pulls everything since the last successful run (minus a short overlap) (see oura/sync.py and the
# oura.sync_log table) and upserts it into the oura schema in garbanzodb.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/venv/bin/python"

if [[ ! -x "$VENV_PY" ]]; then
    echo "Error: venv not found at $SCRIPT_DIR/venv — run:" >&2
    echo "  cd $SCRIPT_DIR && python3 -m venv venv && ./venv/bin/pip install -r requirements.txt" >&2
    exit 1
fi

cd "$SCRIPT_DIR"
exec "$VENV_PY" sync.py
