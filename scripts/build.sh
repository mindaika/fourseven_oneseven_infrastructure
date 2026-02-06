#!/bin/bash
# Build and deploy applications

set -e

echo "🔨 Building applications..."

# Check if frontend dist exists
FRONTEND_DIST=~/Source/fourseven_oneseven_frontend/dist
if [ ! -d "$FRONTEND_DIST" ] || [ -z "$(ls -A "$FRONTEND_DIST" 2>/dev/null)" ]; then
    echo "⚠️  Frontend not built yet!"
    echo "Building frontend..."
    cd ~/Source/fourseven_oneseven_frontend && npm install && npm run build
fi

# Build backend services
echo "🔧 Building backend services..."
cd ~/Source/fourseven_oneseven_infrastructure/apps && docker compose build --no-cache

# Restart services
echo "🔄 Restarting services..."
cd ~/Source/fourseven_oneseven_infrastructure/apps && docker compose up -d

# Restart nginx to pick up new frontend
echo "🌐 Restarting nginx..."
docker restart nginx

echo "✅ Build and deployment complete!"
echo ""
echo "Check logs with: ~/Source/fourseven_oneseven_infrastructure/scripts/logs.sh apps -f"
