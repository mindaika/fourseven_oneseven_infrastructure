#!/usr/bin/env bash
# Backup infrastructure services to Synology NAS via NFS
# Syncs: Home Assistant backups, PostgreSQL dump, Pi-hole config
# Runs daily at 6 AM via cron (after HA's ~5:30 AM auto-backup)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$INFRA_DIR")"

# Load config from infrastructure .env
set -a
source "$INFRA_DIR/.env"
set +a

NAS_MOUNT="/mnt/synology-backup"
NAS_BACKUP_DIR="$NAS_MOUNT/pi-backups"
POSTGRES_RETENTION_DAYS=14

HA_BACKUP_SRC="$REPO_DIR/homeassistant/config/backups"
PIHOLE_BACKUP_SRC="$INFRA_DIR/backups/pihole-teleporter.tar.gz"

TIMESTAMP="$(date +%Y-%m-%d_%H%M)"

# Ensure NFS mount is available
if ! mountpoint -q "$NAS_MOUNT"; then
    echo "NFS not mounted, attempting mount..."
    sudo mount "$NAS_MOUNT" || { echo "Error: Failed to mount $NAS_MOUNT" >&2; exit 1; }
fi

# Create NAS directory structure
mkdir -p "$NAS_BACKUP_DIR/homeassistant" \
         "$NAS_BACKUP_DIR/postgres" \
         "$NAS_BACKUP_DIR/pihole"

# --- Home Assistant backups ---
echo "Syncing Home Assistant backups..."
if [[ -d "$HA_BACKUP_SRC" ]]; then
    rsync -a --delete "$HA_BACKUP_SRC/" "$NAS_BACKUP_DIR/homeassistant/"
    HA_COUNT=$(find "$NAS_BACKUP_DIR/homeassistant" -mindepth 1 -maxdepth 1 | wc -l)
    echo "  Synced $HA_COUNT backup(s) to NAS"
else
    echo "  Warning: HA backup directory not found at $HA_BACKUP_SRC" >&2
fi

# --- PostgreSQL dump ---
echo "Dumping PostgreSQL..."
PG_DUMP_FILE="$NAS_BACKUP_DIR/postgres/pgdumpall_${TIMESTAMP}.sql.gz"
docker exec postgres pg_dumpall -U "$POSTGRES_USER" | gzip > "$PG_DUMP_FILE"
PG_SIZE=$(du -h "$PG_DUMP_FILE" | cut -f1)
echo "  Saved $PG_DUMP_FILE ($PG_SIZE)"

# Clean up old Postgres dumps
find "$NAS_BACKUP_DIR/postgres" -name "pgdumpall_*.sql.gz" -mtime +$POSTGRES_RETENTION_DAYS -delete
PG_REMAINING=$(find "$NAS_BACKUP_DIR/postgres" -name "pgdumpall_*.sql.gz" | wc -l)
echo "  Keeping $PG_REMAINING dump(s) (${POSTGRES_RETENTION_DAYS}-day retention)"

# --- Pi-hole backup ---
echo "Copying Pi-hole backup..."
if [[ -f "$PIHOLE_BACKUP_SRC" ]]; then
    cp "$PIHOLE_BACKUP_SRC" "$NAS_BACKUP_DIR/pihole/pihole-teleporter.tar.gz"
    PH_SIZE=$(du -h "$NAS_BACKUP_DIR/pihole/pihole-teleporter.tar.gz" | cut -f1)
    echo "  Copied Pi-hole backup ($PH_SIZE)"
else
    echo "  Warning: Pi-hole backup not found at $PIHOLE_BACKUP_SRC (run pihole-backup.sh first)" >&2
fi

echo "Backup complete at $(date '+%Y-%m-%d %H:%M:%S')"
