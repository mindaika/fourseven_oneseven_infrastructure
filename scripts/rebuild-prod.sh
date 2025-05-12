#!/bin/bash
echo "Starting production rebuild..."

# Skip the Vite build since we're copying from development
echo "Skipping Vite build (using files copied from dev environment)..."

# Check if dist directory exists and contains files
if [ ! -d "/home/pi/fourseven_oneseven/fourseven_oneseven_frontend/dist" ] || [ -z "$(ls -A /home/pi/fourseven_oneseven/fourseven_oneseven_frontend/dist)" ]; then
    echo "ERROR: Missing or empty dist directory!"
    echo "Please build on your dev machine and copy files first:"
    echo "  On dev: yarn build --mode development"
    echo "  On dev: rsync -avz dist/ pi@your-pi-address:/home/pi/fourseven_oneseven/fourseven_oneseven_frontend/dist/"
    exit 1
fi

echo "Frontend files present, proceeding with deployment..."

cd /home/pi/fourseven_oneseven/fourseven_oneseven_infrastructure
echo "Stopping existing services..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file .env down

echo "Rebuilding images..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file .env build --no-cache

echo "Starting services..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file .env up -d

echo "Checking status..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file .env ps

echo "Showing logs..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file .env logs

echo "Rebuild complete!"