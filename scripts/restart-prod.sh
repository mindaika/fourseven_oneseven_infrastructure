#!/bin/bash
docker compose --env-file .env -f docker/docker-compose.yml -f docker/docker-compose.prod.yml down
docker compose --env-file .env -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d
