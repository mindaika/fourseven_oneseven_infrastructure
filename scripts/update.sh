#!/bin/bash
# Update all services to latest versions

set -e

echo "⬆️  Updating all services..."

# Pull latest images
echo "📥 Pulling latest infrastructure images..."
cd ~/Source/fourseven_oneseven_infrastructure/infrastructure && docker compose pull

echo "📥 Pulling latest Home Assistant images..."
cd ~/Source/fourseven_oneseven_infrastructure/homeassistant && docker compose pull

# Restart services with new images
echo "🔄 Restarting services..."
cd ~/Source/fourseven_oneseven_infrastructure/infrastructure && docker compose up -d
cd ~/Source/fourseven_oneseven_infrastructure/homeassistant && docker compose up -d

# Note: Apps need to be rebuilt, not pulled
echo "ℹ️  Note: Applications need to be rebuilt with: ~/Source/fourseven_oneseven_infrastructure/scripts/build.sh"

echo "✅ Update complete!"
echo ""
echo "Run ~/Source/fourseven_oneseven_infrastructure/scripts/build.sh to update applications"
