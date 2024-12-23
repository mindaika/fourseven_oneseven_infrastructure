#!/bin/bash

cd ../fourseven_oneseven
echo "Building Vite application..."
npm run build

cd ../fourseven_oneseven_infrastructure
echo "Stopping existing services..."
docker compose --env-file .env -f docker/docker-compose.yml -f docker/docker-compose.dev.yml down

echo "Rebuilding images..."
docker compose --env-file .env -f docker/docker-compose.yml -f docker/docker-compose.dev.yml build #--no-cache

echo "Starting services..."
docker compose --env-file .env -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d

echo "Checking status..."
docker compose --env-file .env -f docker/docker-compose.yml -f docker/docker-compose.dev.yml ps

echo "Showing logs..."
docker compose --env-file .env -f docker/docker-compose.yml -f docker/docker-compose.dev.yml logs

