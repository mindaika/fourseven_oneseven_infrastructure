#!/bin/bash
# Show status of all services

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Load network config from infrastructure .env
set -a
source "$REPO_DIR/infrastructure/.env"
set +a

echo "📊 Pi5 Services Status"
echo "====================="
echo ""

echo "🏗️  Infrastructure:"
cd "$REPO_DIR/infrastructure" && docker compose ps

echo ""
echo "🔧 Applications:"
cd "$REPO_DIR/apps" && docker compose ps

echo ""
echo "🏠 Home Assistant:"
cd "$REPO_DIR/homeassistant" && docker compose ps

echo ""
echo "💾 Disk Usage:"
docker system df

echo ""
echo "🌐 Access URLs:"
echo "  Pi-hole:         http://${HOST_IP}:8080/admin"
echo "  Home Assistant:  http://${HOST_IP}:8123"
echo "  Website:         https://garbanzo.monster"
