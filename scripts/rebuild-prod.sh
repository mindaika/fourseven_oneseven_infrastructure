#!/bin/bash

echo "Building Vite application..."
npm run build

echo "Stopping existing services..."
docker compose -f docker-compose.prod.yml down

echo "Rebuilding images..."
docker compose -f docker-compose.prod.yml build --no-cache

echo "Starting services..."
docker compose -f docker-compose.prod.yml up -d

echo "Checking status..."
docker compose -f docker-compose.prod.yml ps

echo "Showing logs..."
docker compose -f docker-compose.prod.yml logs