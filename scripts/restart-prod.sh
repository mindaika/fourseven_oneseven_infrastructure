#!/bin/bash
docker compose -f ./docker/compose.yaml -f ./docker/compose.prod.yaml --env-file .env down
docker compose -f ./docker/compose.yaml -f ./docker/compose.prod.yaml --env-file .env up -d --build