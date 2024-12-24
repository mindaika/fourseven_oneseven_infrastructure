#!/bin/bash
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file .env down
docker compose -f ./docker/docker-compose.yml -f ./docker/docker-compose.prod.yml --env-file .env up -d --build