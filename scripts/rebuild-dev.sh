#!/bin/bash
echo "Starting development rebuild..."

cd /home/pi/fourseven_oneseven/fourseven_oneseven_infrastructure

# Check if environment file exists
ENV_FILE="./environments/.env.development"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: Environment file not found: $ENV_FILE"
    echo "Please run setup-env.sh first:"
    echo "  ./scripts/setup-env.sh development"
    exit 1
fi

echo "Stopping existing services..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.dev.yml --env-file "$ENV_FILE" down

echo "Rebuilding images..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.dev.yml --env-file "$ENV_FILE" build --no-cache

echo "Starting services..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.dev.yml --env-file "$ENV_FILE" up -d

echo "Checking status..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.dev.yml --env-file "$ENV_FILE" ps

echo "Showing logs..."
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.dev.yml --env-file "$ENV_FILE" logs

echo "Rebuild complete!"