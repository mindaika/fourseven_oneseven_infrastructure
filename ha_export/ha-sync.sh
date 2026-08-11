#!/usr/bin/env bash
# Hourly Home Assistant statistics sync.
#
# Re-reads the last 72 hours and upserts. The overlap is deliberate: Home
# Assistant revises recent statistics, and its repair UI lets them be corrected
# by hand, so a strict high-water mark would import the first (wrong) value and
# keep it forever.
#
# Runs at :10 past the hour, after HA compiles the hour that just closed. That
# offset is an assumption, not a measured fact -- if a run lands before HA has
# finished, the next hour's overlap picks the data up anyway.
#
# Exits nonzero on failure so cron surfaces it. Note that a failure which
# prevents writing to Postgres cannot be recorded in sync_run either, so this
# log and the age of last_success_at in reporting.ha_source_status are the
# monitoring of last resort.
#
# Usage:  ha-sync.sh [incremental|backfill|reconcile|health]  (default: incremental)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/venv/bin/python"
COMMAND="${1:-incremental}"

if [[ ! -x "$VENV_PY" ]]; then
    echo "Error: venv not found at $SCRIPT_DIR/venv - run:" >&2
    echo "  cd $SCRIPT_DIR && python3 -m venv venv && ./venv/bin/pip install -r requirements.txt" >&2
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "Error: $SCRIPT_DIR/.env not found (copy .env.example and fill it in)" >&2
    exit 1
fi

cd "$SCRIPT_DIR"
echo "--- $(date -Is) ha-sync $COMMAND ---"
exec "$VENV_PY" ha_sync.py "$COMMAND"
