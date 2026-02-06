#!/bin/bash
# Stop all services

set -e

echo "🛑 Stopping Pi5 services..."

# Stop in reverse order
echo "🏠 Stopping Home Assistant..."
cd ~/Source/fourseven_oneseven_infrastructure/homeassistant && docker compose down

echo "🔧 Stopping applications..."
cd ~/Source/fourseven_oneseven_infrastructure/apps && docker compose down

echo "📦 Stopping infrastructure..."
cd ~/Source/fourseven_oneseven_infrastructure/infrastructure && docker compose down

echo "✅ All services stopped!"
