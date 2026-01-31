#!/bin/bash
echo "Starting production rebuild..."

# Get script directory and navigate to infrastructure root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$INFRASTRUCTURE_DIR")"
cd "$INFRASTRUCTURE_DIR"

# Check if dist directory exists and contains files
FRONTEND_DIST="$PROJECT_ROOT/fourseven_oneseven_frontend/dist"
if [ ! -d "$FRONTEND_DIST" ] || [ -z "$(ls -A "$FRONTEND_DIST" 2>/dev/null)" ]; then
    echo "WARNING: Missing or empty frontend dist directory at $FRONTEND_DIST"
    echo "The production build requires pre-built frontend files."
    echo "You can either:"
    echo "  1. Build the frontend first: cd ../fourseven_oneseven_frontend && yarn build"
    echo "  2. Continue without frontend (backend services only)"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if environment file exists
ENV_FILE="./environments/.env.production"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: Environment file not found: $ENV_FILE"
    echo "Please run setup-env.sh first:"
    echo "  ./scripts/setup-env.sh production"
    exit 1
fi

echo "Stopping existing services..."
docker compose -f ./docker/compose.yaml -f ./docker/compose.prod.yaml --env-file "$ENV_FILE" down

echo "Rebuilding images..."
docker compose -f ./docker/compose.yaml -f ./docker/compose.prod.yaml --env-file "$ENV_FILE" build --no-cache

echo "Starting services..."
docker compose -f ./docker/compose.yaml -f ./docker/compose.prod.yaml --env-file "$ENV_FILE" up -d

echo "Checking status..."
docker compose -f ./docker/compose.yaml -f ./docker/compose.prod.yaml --env-file "$ENV_FILE" ps

echo "Showing logs..."
docker compose -f ./docker/compose.yaml -f ./docker/compose.prod.yaml --env-file "$ENV_FILE" logs

echo "Rebuild complete!"