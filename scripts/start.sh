#!/bin/bash
# Start all services in order

set -e

echo "🚀 Starting Pi5 services..."

# Start infrastructure first (PostgreSQL, Pi-hole, nginx)
echo "📦 Starting infrastructure..."
cd ~/Source/fourseven_oneseven_infrastructure/infrastructure && docker compose up -d

# Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL..."
sleep 5

# Start applications
echo "🔧 Starting applications..."
cd ~/Source/fourseven_oneseven_infrastructure/apps && docker compose up -d

# Start Home Assistant
echo "🏠 Starting Home Assistant..."
cd ~/Source/fourseven_oneseven_infrastructure/homeassistant && docker compose up -d

echo "✅ All services started!"
echo ""
echo "Check status with: ~/Source/fourseven_oneseven_infrastructure/scripts/status.sh"
echo "View logs with: ~/Source/fourseven_oneseven_infrastructure/scripts/logs.sh"
