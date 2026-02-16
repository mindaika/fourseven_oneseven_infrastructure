#!/usr/bin/env bash
# Pi-hole Teleporter backup script
# Exports Pi-hole config (blocklists, domains, settings) via the v6 API
# and saves to the repo for version control.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$INFRA_DIR/backups"
ENV_FILE="$INFRA_DIR/.env"
PIHOLE_API="http://localhost:8080/api"

# Read password from .env
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi
PIHOLE_PASSWORD=$(grep '^PIHOLE_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2-)

mkdir -p "$BACKUP_DIR"

# Authenticate and get session ID
SID=$(curl -s -X POST "$PIHOLE_API/auth" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"$PIHOLE_PASSWORD\"}" | jq -r '.session.sid')

if [[ -z "$SID" || "$SID" == "null" ]]; then
    echo "Error: Failed to authenticate with Pi-hole API" >&2
    exit 1
fi

# Export teleporter backup
BACKUP_FILE="$BACKUP_DIR/pihole-teleporter.tar.gz"
HTTP_CODE=$(curl -s -o "$BACKUP_FILE" -w "%{http_code}" \
    -H "sid: $SID" \
    "$PIHOLE_API/teleporter")

# Logout
curl -s -X DELETE -H "sid: $SID" "$PIHOLE_API/auth" > /dev/null

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: Teleporter export failed (HTTP $HTTP_CODE)" >&2
    rm -f "$BACKUP_FILE"
    exit 1
fi

echo "Backup saved to $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
