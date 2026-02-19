#!/bin/bash
# Build and deploy applications

set -e

# Derive paths relative to this script's location (scripts/ -> infrastructure/ -> Source/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INFRA_DIR="$SOURCE_DIR/fourseven_oneseven_infrastructure"
FRONTEND_DIR="$SOURCE_DIR/fourseven_oneseven_frontend"

echo "🔨 Building applications..."

# Check if frontend dist exists
FRONTEND_DIST="$FRONTEND_DIR/dist"
if [ ! -d "$FRONTEND_DIST" ] || [ -z "$(ls -A "$FRONTEND_DIST" 2>/dev/null)" ]; then
    echo "⚠️  Frontend not built yet!"
    echo "Building frontend..."
    cd "$FRONTEND_DIR" && npm install && npm run build
fi

# Build backend services
echo "🔧 Building backend services..."
cd "$INFRA_DIR/apps" && docker compose build --no-cache

# Restart services
echo "🔄 Restarting services..."
cd "$INFRA_DIR/apps" && docker compose up -d

# Restart nginx to pick up new frontend
echo "🌐 Restarting nginx..."
docker restart nginx

echo "✅ Build and deployment complete!"
echo ""
echo "Check logs with: $INFRA_DIR/scripts/logs.sh apps -f"
