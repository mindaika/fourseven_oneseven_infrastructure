#!/bin/bash
# Start local development environment (no nginx/SSL)

set -e

# Derive paths relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INFRA_DIR="$SOURCE_DIR/fourseven_oneseven_infrastructure"
FRONTEND_DIR="$SOURCE_DIR/fourseven_oneseven_frontend"

echo "Starting local dev environment..."

# Create Docker networks if they don't exist
docker network create infra_network 2>/dev/null || true
docker network create apps_network 2>/dev/null || true

# Start PostgreSQL only (skip nginx, pihole)
echo "Starting PostgreSQL..."
cd "$INFRA_DIR/infrastructure" && docker compose up -d postgres

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL..."
until docker exec postgres pg_isready -U garbanzo -d garbanzodb > /dev/null 2>&1; do
    sleep 1
done
echo "PostgreSQL is ready."

# Build and start app services
echo "Starting app services (jobify, pixify, dancetrak)..."
cd "$INFRA_DIR/apps" && docker compose up -d --build

# Start Vite dev server (foreground so Ctrl+C stops it)
echo ""
echo "All services running. Starting frontend dev server..."
echo "  Frontend: http://localhost:5174"
echo "  Jobify:   http://localhost:5004 (via Docker)"
echo "  Pixify:   http://localhost:5005 (via Docker)"
echo "  DanceTrak: http://localhost:5006 (via Docker)"
echo "  Postgres: localhost:5432"
echo ""
echo "Press Ctrl+C to stop the frontend dev server."
echo "Run 'docker compose down' in apps/ and infrastructure/ to stop backend services."
echo ""
cd "$FRONTEND_DIR" && npm run dev
