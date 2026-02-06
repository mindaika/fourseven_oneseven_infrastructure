#!/bin/bash
# Show status of all services

echo "📊 Pi5 Services Status"
echo "====================="
echo ""

echo "🏗️  Infrastructure:"
cd ~/Source/fourseven_oneseven_infrastructure/infrastructure && docker compose ps

echo ""
echo "🔧 Applications:"
cd ~/Source/fourseven_oneseven_infrastructure/apps && docker compose ps

echo ""
echo "🏠 Home Assistant:"
cd ~/Source/fourseven_oneseven_infrastructure/homeassistant && docker compose ps

echo ""
echo "💾 Disk Usage:"
docker system df

echo ""
echo "🌐 Access URLs:"
echo "  Pi-hole:         http://192.168.1.54:8080/admin"
echo "  Home Assistant:  http://192.168.1.54:8123"
echo "  Website:         https://garbanzo.monster"
