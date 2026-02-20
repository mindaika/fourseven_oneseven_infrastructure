#!/bin/bash
# Start local development environment (no nginx/SSL)

set -e

# Derive paths relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INFRA_DIR="$SOURCE_DIR/fourseven_oneseven_infrastructure"
FRONTEND_DIR="$SOURCE_DIR/fourseven_oneseven_frontend"

echo "Starting local dev environment..."
echo "Using Pi5 PostgreSQL at 192.168.1.54:5432"

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
echo "  Postgres: 192.168.1.54:5432 (Pi5)"
echo ""
echo "Press Ctrl+C to stop the frontend dev server."
echo "Run 'docker compose down' in apps/ and infrastructure/ to stop backend services."
echo ""
cd "$FRONTEND_DIR" && npm run dev
