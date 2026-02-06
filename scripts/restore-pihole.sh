#!/bin/bash
# Restore Pi-hole configuration from backup

set -e

BACKUP_DIR=~/Source/fourseven_oneseven_infrastructure/infrastructure/pihole-backup

if [ ! -d "$BACKUP_DIR" ]; then
    echo "❌ No Pi-hole backup found at $BACKUP_DIR"
    echo "Run migrate-from-pi4.sh first"
    exit 1
fi

echo "🕳️  Restoring Pi-hole configuration..."

# Pi-hole needs to be running first
if ! docker ps | grep -q pihole; then
    echo "❌ Pi-hole container not running"
    echo "Start it first with: cd ~/Source/fourseven_oneseven_infrastructure/infrastructure && docker compose up -d pihole"
    exit 1
fi

# Copy configuration into the running container
echo "Copying configuration..."
docker cp $BACKUP_DIR/pihole/. pihole:/etc/pihole/
[ -d $BACKUP_DIR/dnsmasq.d ] && docker cp $BACKUP_DIR/dnsmasq.d/. pihole:/etc/dnsmasq.d/ || true

# Restart Pi-hole to pick up new config
echo "Restarting Pi-hole..."
docker restart pihole

echo "✅ Pi-hole configuration restored!"
echo ""
echo "Access Pi-hole at: http://192.168.1.54:8080/admin"
