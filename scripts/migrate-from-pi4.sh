#!/bin/bash
# Migrate data from Pi4 to Pi5

set -e

PI4_IP="192.168.1.5"
PI4_USER="pi"

echo "🔄 Migrating from Pi4 to Pi5..."
echo ""

# Check if we can reach Pi4
if ! ping -c 1 $PI4_IP &> /dev/null; then
    echo "❌ Cannot reach Pi4 at $PI4_IP"
    echo "Make sure Pi4 is online and accessible"
    exit 1
fi

echo "📋 What would you like to migrate?"
echo "1) SSL certificates (/etc/letsencrypt)"
echo "2) Pi-hole configuration"
echo "3) Environment files from old infrastructure"
echo "4) All of the above"
echo ""
read -p "Choice (1-4): " choice

migrate_ssl() {
    echo "🔐 Migrating SSL certificates..."

    # Create temporary directory
    TEMP_DIR=$(mktemp -d)

    # Copy from Pi4 using SSH with sudo and tar piping
    echo "Copying from Pi4 (requires sudo on Pi4)..."
    ssh $PI4_USER@$PI4_IP "sudo tar czf - -C /etc letsencrypt 2>/dev/null" | tar xzf - -C $TEMP_DIR/

    if [ ! -d "$TEMP_DIR/letsencrypt" ]; then
        echo "❌ Failed to copy SSL certificates"
        rm -rf $TEMP_DIR
        return 1
    fi

    # Move to proper location with sudo
    echo "Installing certificates..."
    sudo mkdir -p /etc/letsencrypt
    sudo cp -r $TEMP_DIR/letsencrypt/* /etc/letsencrypt/
    sudo chown -R root:root /etc/letsencrypt
    sudo chmod -R 755 /etc/letsencrypt

    # Cleanup
    rm -rf $TEMP_DIR

    echo "✅ SSL certificates migrated!"
}

migrate_pihole() {
    echo "🕳️  Migrating Pi-hole configuration..."

    # Create temporary directory
    TEMP_DIR=$(mktemp -d)

    # Copy Pi-hole config from Pi4 using SSH with sudo
    echo "Copying Pi-hole data from Pi4 (requires sudo on Pi4)..."
    ssh $PI4_USER@$PI4_IP "sudo tar czf - -C /etc pihole 2>/dev/null" | tar xzf - -C $TEMP_DIR/ || true
    ssh $PI4_USER@$PI4_IP "sudo tar czf - -C /etc dnsmasq.d 2>/dev/null" | tar xzf - -C $TEMP_DIR/ 2>/dev/null || true

    # Note: We'll restore this into the Docker volume after Pi-hole starts
    mkdir -p ~/Source/fourseven_oneseven_infrastructure/infrastructure/pihole-backup
    [ -d "$TEMP_DIR/pihole" ] && cp -r $TEMP_DIR/pihole ~/Source/fourseven_oneseven_infrastructure/infrastructure/pihole-backup/
    [ -d "$TEMP_DIR/dnsmasq.d" ] && cp -r $TEMP_DIR/dnsmasq.d ~/Source/fourseven_oneseven_infrastructure/infrastructure/pihole-backup/

    # Cleanup
    rm -rf $TEMP_DIR

    echo "✅ Pi-hole configuration backed up to ~/Source/fourseven_oneseven_infrastructure/infrastructure/pihole-backup/"
    echo "ℹ️  After starting Pi-hole, run: ~/Source/fourseven_oneseven_infrastructure/scripts/restore-pihole.sh"
}

migrate_env() {
    echo "🔧 Migrating environment files..."

    # Try to find old environment files
    scp $PI4_USER@$PI4_IP:~/Source/fourseven_oneseven_infrastructure/environments/.env.production \
        ~/Source/fourseven_oneseven_infrastructure/env-backup.txt 2>/dev/null || true

    if [ -f ~/Source/fourseven_oneseven_infrastructure/env-backup.txt ]; then
        echo "✅ Environment file backed up to ~/Source/fourseven_oneseven_infrastructure/env-backup.txt"
        echo "ℹ️  Review and copy values to:"
        echo "   - ~/Source/fourseven_oneseven_infrastructure/infrastructure/.env"
        echo "   - ~/Source/fourseven_oneseven_infrastructure/apps/.env"
    else
        echo "⚠️  Could not find environment file on Pi4"
    fi
}

case $choice in
    1)
        migrate_ssl
        ;;
    2)
        migrate_pihole
        ;;
    3)
        migrate_env
        ;;
    4)
        migrate_ssl
        migrate_pihole
        migrate_env
        ;;
    *)
        echo "❌ Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "✅ Migration complete!"
echo ""
echo "Next steps:"
echo "1. Edit environment files and add your secrets"
echo "2. Review migrated configs"
echo "3. Start services with: ~/Source/fourseven_oneseven_infrastructure/scripts/start.sh"
