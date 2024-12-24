#!/bin/bash

echo "Building Vite application..."
cd /home/pi/fourseven_oneseven/fourseven_oneseven_frontend
npm run build
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