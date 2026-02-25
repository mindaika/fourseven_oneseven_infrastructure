#!/bin/bash
# Start all services in order

set -e

echo "🚀 Starting Pi5 services..."

# Start applications first so compose creates apps_network with proper labels
# (nginx in infrastructure needs to join this network)
# App containers will retry via restart: unless-stopped until postgres is ready
echo "🔧 Starting applications..."
cd ~/Source/fourseven_oneseven_infrastructure/apps && docker compose up -d

# Start infrastructure (PostgreSQL, Pi-hole, nginx)
# nginx can now join the already-existing apps_network
echo "📦 Starting infrastructure..."
cd ~/Source/fourseven_oneseven_infrastructure/infrastructure && docker compose up -d

# Start Home Assistant
echo "🏠 Starting Home Assistant..."
cd ~/Source/fourseven_oneseven_infrastructure/homeassistant && docker compose up -d

echo "✅ All services started!"
echo ""
echo "Check status with: ~/Source/fourseven_oneseven_infrastructure/scripts/status.sh"
echo "View logs with: ~/Source/fourseven_oneseven_infrastructure/scripts/logs.sh"
