#!/bin/bash
# deploy-to-pi.sh - Deploy pre-built images to Pi
# This replaces rebuild-prod.sh for Pi deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING: $1${NC}"
}

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$INFRASTRUCTURE_ROOT")"

# Load multiarch configuration
if [ ! -f "$PROJECT_ROOT/.multiarch-config" ]; then
    error "Multi-arch not configured. Run ./scripts/setup-multiarch.sh first"
fi

source "$PROJECT_ROOT/.multiarch-config"

# Default environment
ENVIRONMENT=${1:-production}

# Validate environment parameter
if [[ "$ENVIRONMENT" != "development" && "$ENVIRONMENT" != "production" ]]; then
    error "Environment must be 'development' or 'production'"
fi

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}      Deploying to Pi                   ${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
info "Environment: $ENVIRONMENT"
info "Registry: ${REGISTRY_HOST}:${REGISTRY_PORT}"
info "Target Pi: $PI_USER@$PI_HOST"
echo ""

cd "$INFRASTRUCTURE_ROOT"

# Check if environment file exists
ENV_FILE="./environments/.env.$ENVIRONMENT"
if [ ! -f "$ENV_FILE" ]; then
    error "Environment file not found: $ENV_FILE"
fi

# Check if registry compose override exists
REGISTRY_COMPOSE="docker/docker-compose.registry.yml"
if [ ! -f "$REGISTRY_COMPOSE" ]; then
    error "Registry compose file not found. Run ./scripts/build-multiarch.sh first"
fi

# Test connectivity
test_connectivity() {
    log "Testing connectivity..."
    
    # Test Pi connectivity
    if ! ping -c 1 "$PI_HOST" >/dev/null 2>&1; then
        error "Cannot reach Pi at $PI_HOST"
    fi
    
    # Test SSH access
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$PI_USER@$PI_HOST" true 2>/dev/null; then
        error "Cannot SSH to $PI_USER@$PI_HOST"
    fi
    
    # Test registry accessibility from Pi
    if ! ssh "$PI_USER@$PI_HOST" "curl -f http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/ >/dev/null 2>&1"; then
        error "Pi cannot access registry at ${REGISTRY_HOST}:${REGISTRY_PORT}"
    fi
    
    log "✓ Connectivity tests passed"
}

# Copy deployment files to Pi
copy_deployment_files() {
    log "Copying deployment files to Pi..."
    
    # Create deployment directory on Pi
    ssh "$PI_USER@$PI_HOST" "mkdir -p ~/fourseven_oneseven_deploy"
    
    # Copy compose files
    scp "./docker/docker-compose.yml" "$PI_USER@$PI_HOST:~/fourseven_oneseven_deploy/"
    scp "./docker/docker-compose.prod.yml" "$PI_USER@$PI_HOST:~/fourseven_oneseven_deploy/"
    scp "$REGISTRY_COMPOSE" "$PI_USER@$PI_HOST:~/fourseven_oneseven_deploy/"
    
    # Copy environment file
    scp "$ENV_FILE" "$PI_USER@$PI_HOST:~/fourseven_oneseven_deploy/.env"
    
    log "✓ Deployment files copied"
}

# Deploy on Pi
deploy_on_pi() {
    log "Deploying on Pi..."
    
    ssh "$PI_USER@$PI_HOST" "
        cd ~/fourseven_oneseven_deploy
        
        # Stop existing services
        echo 'Stopping existing services...'
        docker compose \\
            -f docker-compose.yml \\
            -f docker-compose.prod.yml \\
            -f docker-compose.registry.yml \\
            --env-file .env \\
            down || true
        
        # Pull latest images
        echo 'Pulling latest images...'
        docker compose \\
            -f docker-compose.yml \\
            -f docker-compose.prod.yml \\
            -f docker-compose.registry.yml \\
            --env-file .env \\
            pull
        
        # Start services
        echo 'Starting services...'
        docker compose \\
            -f docker-compose.yml \\
            -f docker-compose.prod.yml \\
            -f docker-compose.registry.yml \\
            --env-file .env \\
            up -d
        
        # Wait a moment for services to start
        sleep 10
        
        # Show status
        echo 'Service status:'
        docker compose \\
            -f docker-compose.yml \\
            -f docker-compose.prod.yml \\
            -f docker-compose.registry.yml \\
            --env-file .env \\
            ps
    "
    
    log "✓ Deployment complete"
}

# Health check
health_check() {
    log "Performing health check..."
    
    # Give services time to start up
    sleep 15
    
    # Check if services are responding
    ssh "$PI_USER@$PI_HOST" "
        cd ~/fourseven_oneseven_deploy
        
        # Check service health
        echo 'Health check results:'
        
        # Check if containers are running
        if docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.registry.yml ps | grep -q 'Up'; then
            echo '✓ Containers are running'
        else
            echo '✗ Some containers may not be running'
            docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.registry.yml ps
            exit 1
        fi
        
        # Check nginx
        if curl -f http://localhost:80 >/dev/null 2>&1; then
            echo '✓ Nginx is responding'
        else
            echo '✗ Nginx is not responding'
        fi
        
        # Check jobify health endpoint
        if curl -f http://localhost:5004/api/status >/dev/null 2>&1; then
            echo '✓ Jobify API is responding'
        else
            echo '✗ Jobify API is not responding'
        fi
        
        # Check pixify health endpoint  
        if curl -f http://localhost:5005/api/status >/dev/null 2>&1; then
            echo '✓ Pixify API is responding'
        else
            echo '✗ Pixify API is not responding'
        fi
    "
    
    log "✓ Health check complete"
}

# Show deployment info
show_deployment_info() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}      Deployment Successful!            ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo -e "${YELLOW}Application URLs:${NC}"
    echo "  • Main site: ${BLUE}http://${PI_HOST}${NC}"
    echo "  • Jobify: ${BLUE}http://${PI_HOST}/jobify/${NC}"
    echo "  • Pixify: ${BLUE}http://${PI_HOST}/pixify/${NC}"
    echo ""
    echo -e "${YELLOW}Management Commands:${NC}"
    echo "  • Check status: ${BLUE}ssh $PI_USER@$PI_HOST 'cd ~/fourseven_oneseven_deploy && docker compose ps'${NC}"
    echo "  • View logs: ${BLUE}ssh $PI_USER@$PI_HOST 'cd ~/fourseven_oneseven_deploy && docker compose logs -f'${NC}"
    echo "  • Restart: ${BLUE}./scripts/deploy-to-pi.sh $ENVIRONMENT${NC}"
    echo ""
}

# Show logs
show_logs() {
    log "Showing recent logs..."
    ssh "$PI_USER@$PI_HOST" "
        cd ~/fourseven_oneseven_deploy
        docker compose \\
            -f docker-compose.yml \\
            -f docker-compose.prod.yml \\
            -f docker-compose.registry.yml \\
            logs --tail=50
    "
}

# Main deployment process
main() {
    test_connectivity
    copy_deployment_files
    deploy_on_pi
    health_check
    show_deployment_info
}

# Handle script arguments
case "${1:-production}" in
    "development"|"production")
        main
        ;;
    "status")
        log "Checking Pi deployment status..."
        ssh "$PI_USER@$PI_HOST" "
            cd ~/fourseven_oneseven_deploy 2>/dev/null || { echo 'No deployment found'; exit 1; }
            docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.registry.yml ps
        "
        ;;
    "logs")
        show_logs
        ;;
    "health")
        health_check
        ;;
    "stop")
        log "Stopping services on Pi..."
        ssh "$PI_USER@$PI_HOST" "
            cd ~/fourseven_oneseven_deploy 2>/dev/null || { echo 'No deployment found'; exit 1; }
            docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.registry.yml down
        "
        ;;
    *)
        echo "Usage: $0 [production|development|status|logs|health|stop]"
        echo "  production  - Deploy production environment (default)"
        echo "  development - Deploy development environment"
        echo "  status      - Check deployment status"
        echo "  logs        - Show recent logs"
        echo "  health      - Run health check"
        echo "  stop        - Stop all services"
        exit 1
        ;;
esac