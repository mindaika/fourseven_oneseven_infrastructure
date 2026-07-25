#!/usr/bin/env bash
# Dynamic DNS updater for garbanzo.monster (Namecheap).
# Checks the Pi's current public IP against what DNS currently publishes,
# and only calls Namecheap's update API if they've drifted apart.
#
# Replaces the Synology's built-in DDNS client, which failed silently and
# let the A record go stale for an unknown period (found 2026-07-25) —
# nothing here depends on the Synology being reachable or configured right.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$INFRA_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi
NAMECHEAP_DOMAIN=$(grep '^NAMECHEAP_DOMAIN=' "$ENV_FILE" | cut -d'=' -f2-)
NAMECHEAP_DDNS_PASSWORD=$(grep '^NAMECHEAP_DDNS_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2-)

CURRENT_IP=$(curl -s --max-time 10 https://api.ipify.org)
if [[ ! "$CURRENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: couldn't determine current public IP (got: '$CURRENT_IP')" >&2
    exit 1
fi

DNS_IP=$(curl -s --max-time 10 "https://dns.google/resolve?name=${NAMECHEAP_DOMAIN}&type=A" \
    | python3 -c "import json,sys; a=json.load(sys.stdin).get('Answer',[]); print(next((r['data'] for r in a if r['type']==1), ''))")

if [[ "$CURRENT_IP" == "$DNS_IP" ]]; then
    echo "$(date -Iseconds) DNS already up to date ($CURRENT_IP), nothing to do"
    exit 0
fi

echo "$(date -Iseconds) DNS ($DNS_IP) != current IP ($CURRENT_IP), updating..."
RESPONSE=$(curl -s --max-time 15 "https://dynamicdns.park-your-domain.com/update?host=@&domain=${NAMECHEAP_DOMAIN}&password=${NAMECHEAP_DDNS_PASSWORD}&ip=${CURRENT_IP}")

if echo "$RESPONSE" | grep -q "<ErrCount>0</ErrCount>"; then
    echo "$(date -Iseconds) Updated ${NAMECHEAP_DOMAIN} -> $CURRENT_IP"
else
    echo "$(date -Iseconds) DDNS update FAILED: $RESPONSE" >&2
    exit 1
fi
