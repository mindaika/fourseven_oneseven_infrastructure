#!/bin/bash

echo "Building Vite application..."
npm run build

echo "Stopping existing services..."
docker compose -f docker-compose.dev.yml down

echo "Rebuilding images..."
docker compose -f docker-compose.dev.yml build --no-cache

echo "Starting services..."
docker compose -f docker-compose.dev.yml up -d

echo "Checking status..."
docker compose -f docker-compose.dev.yml ps

echo "Showing logs..."
docker compose -f docker-compose.dev.yml logs