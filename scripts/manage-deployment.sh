#!/bin/bash
# manage-deployment.sh

INFRASTRUCTURE_DIR="/opt/fourseven_oneseven/fourseven_oneseven_infrastructure"
COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE=".env"

# Error handling function
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Change to infrastructure directory
cd "$INFRASTRUCTURE_DIR" || error_exit "Cannot change to infrastructure directory"

# Command parsing
case "$1" in
    start)
        echo "Starting services..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
        ;;
    
    stop)
        echo "Stopping services..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
        ;;
    
    restart)
        echo "Restarting services..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
        ;;
    
    status)
        echo "Checking service status..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps
        ;;
    
    logs)
        shift
        if [ $# -eq 0 ]; then
            echo "Showing all service logs..."
            docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs -f
        else
            echo "Showing logs for $1..."
            docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs -f "$1"
        fi
        ;;
    
    update)
        echo "Pulling latest images..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
        echo "Rebuilding and restarting services..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --build
        docker image prune -f
        ;;
    
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|update} [service]"
        echo "Available services: frontend, jobify, pixify, nginx"
        exit 1
        ;;
esac

exit 0