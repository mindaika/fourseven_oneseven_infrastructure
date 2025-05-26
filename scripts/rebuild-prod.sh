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

# Check if environment file exists
ENV_FILE="./environments/.env.production"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: Environment file not found: $ENV_FILE"
    echo "Please run setup-env.sh first:"
    echo "  ./scripts/setup-env.sh production"
    exit 1
fi

echo "Stopping existing services..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file "$ENV_FILE" down

echo "Rebuilding images..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file "$ENV_FILE" build --no-cache

echo "Starting services..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file "$ENV_FILE" up -d

echo "Checking status..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file "$ENV_FILE" ps

echo "Showing logs..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file "$ENV_FILE" logs

echo "Rebuild complete!"