#!/bin/bash
# build-and-deploy-frontend.sh - Build frontend locally and deploy to Pi

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$INFRASTRUCTURE_DIR")"
FRONTEND_DIR="$PROJECT_ROOT/fourseven_oneseven_frontend"
ENV_FILE="$INFRASTRUCTURE_DIR/environments/.env.production"

# Pi configuration
PI_USER="pi"
PI_HOST="piberry"
PI_STATIC_DIR="/home/pi/fourseven_oneseven/fourseven_oneseven_frontend/dist"

echo -e "${BLUE}=== Frontend Build and Deploy ===${NC}"
echo -e "${BLUE}Frontend dir: $FRONTEND_DIR${NC}"
echo -e "${BLUE}Deploying to: $PI_USER@$PI_HOST:$PI_STATIC_DIR${NC}"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Load environment variables
load_environment() {
    if [[ ! -f "$ENV_FILE" ]]; then
        error_exit "Environment file not found: $ENV_FILE"
    fi
    
    log_info "Loading environment variables..."
    source "$ENV_FILE"
    
    # Validate required Auth0 variables
    local required_vars=("VITE_AUTH0_DOMAIN" "VITE_AUTH0_CLIENT_ID" "VITE_AUTH0_AUDIENCE")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error_exit "Required environment variable not set: $var"
        fi
    done
    
    log_success "Environment loaded and validated"
}

# Build frontend locally
build_frontend() {
    log_info "Building frontend locally..."
    
    if [[ ! -d "$FRONTEND_DIR" ]]; then
        error_exit "Frontend directory not found: $FRONTEND_DIR"
    fi
    
    cd "$FRONTEND_DIR"
    
    # Check for package.json
    if [[ ! -f "package.json" ]]; then
        error_exit "package.json not found in frontend directory"
    fi
    
    # Install dependencies if node_modules is missing or package.json is newer
    if [[ ! -d "node_modules" ]] || [[ "package.json" -nt "node_modules" ]]; then
        log_info "Installing/updating dependencies..."
        npm ci
    fi
    
    # Clean previous build
    log_info "Cleaning previous build..."
    rm -rf dist/
    
    # Build with environment variables
    log_info "Building frontend (this may take a moment)..."
    VITE_AUTH0_DOMAIN="$VITE_AUTH0_DOMAIN" \
    VITE_AUTH0_CLIENT_ID="$VITE_AUTH0_CLIENT_ID" \
    VITE_AUTH0_AUDIENCE="$VITE_AUTH0_AUDIENCE" \
    NODE_ENV=production \
    npm run build
    
    # Verify build output
    if [[ ! -d "dist" ]] || [[ -z "$(ls -A dist/)" ]]; then
        error_exit "Build failed - dist directory is missing or empty"
    fi
    
    local build_size=$(du -sh dist/ | cut -f1)
    log_success "Frontend built successfully (size: $build_size)"
}

# Deploy to Pi via rsync
deploy_to_pi() {
    log_info "Deploying static files to Pi..."
    
    # Test Pi connectivity
    if ! ssh -o ConnectTimeout=10 "$PI_USER@$PI_HOST" "echo 'Connected to Pi'" >/dev/null 2>&1; then
        error_exit "Cannot connect to Pi at $PI_USER@$PI_HOST"
    fi
    
    # Create static directory on Pi if it doesn't exist
    ssh "$PI_USER@$PI_HOST" "mkdir -p $PI_STATIC_DIR"
    
    # Backup current static files
    local backup_dir="$PI_STATIC_DIR.backup.$(date +%Y%m%d_%H%M%S)"
    ssh "$PI_USER@$PI_HOST" "
        if [[ -d '$PI_STATIC_DIR' ]] && [[ -n \"\$(ls -A '$PI_STATIC_DIR' 2>/dev/null)\" ]]; then
            echo 'Creating backup of current static files...'
            cp -r '$PI_STATIC_DIR' '$backup_dir'
            echo 'Backup created: $backup_dir'
        fi
    "
    
    # Deploy new static files
    log_info "Syncing files to Pi..."
    if rsync -avz --delete "$FRONTEND_DIR/dist/" "$PI_USER@$PI_HOST:$PI_STATIC_DIR/"; then
        log_success "Files synced successfully"
    else
        error_exit "Failed to sync files to Pi"
    fi
    
    # Verify deployment
    local remote_files=$(ssh "$PI_USER@$PI_HOST" "find '$PI_STATIC_DIR' -type f | wc -l")
    if [[ "$remote_files" -gt 0 ]]; then
        log_success "Deployment verified ($remote_files files deployed)"
    else
        error_exit "Deployment verification failed - no files found on Pi"
    fi
}

# Restart nginx on Pi
restart_nginx() {
    log_info "Restarting nginx on Pi..."
    
    ssh "$PI_USER@$PI_HOST" "
        cd /home/pi/fourseven_oneseven/fourseven_oneseven_infrastructure/docker
        if docker compose -f docker-compose.prod.yml ps nginx >/dev/null 2>&1; then
            echo 'Restarting nginx container...'
            docker compose -f docker-compose.prod.yml restart nginx
            sleep 3
            if docker compose -f docker-compose.prod.yml ps nginx | grep -q 'Up'; then
                echo 'Nginx restarted successfully'
            else
                echo 'Warning: Nginx may not be running properly'
                docker compose -f docker-compose.prod.yml logs nginx --tail=10
            fi
        else
            echo 'Warning: Nginx container not found or not managed by docker compose'
        fi
    "
}

# Verify deployment
verify_deployment() {
    log_info "Verifying website is responding..."
    
    local max_attempts=5
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Verification attempt $attempt/$max_attempts..."
        
        if curl -s -o /dev/null -w "%{http_code}" "http://$PI_HOST" | grep -q "200\|302\|301"; then
            log_success "✓ Website responding at http://$PI_HOST"
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Website not responding, waiting 10 seconds..."
            sleep 10
        fi
        ((attempt++))
    done
    
    log_error "Website not responding after $max_attempts attempts"
    log_info "You can check manually: http://$PI_HOST"
    return 1
}

# Main execution
main() {
    log_info "Starting frontend build and deployment..."
    
    # Load environment variables
    load_environment
    
    # Build frontend locally
    build_frontend
    
    # Deploy to Pi
    deploy_to_pi
    
    # Restart nginx
    restart_nginx
    
    # Verify deployment
    if verify_deployment; then
        log_success "=== Deployment Successful! ==="
        echo -e "${GREEN}Website: http://$PI_HOST${NC}"
        echo -e "${GREEN}HTTPS: https://garbanzo.monster${NC}"
    else
        log_warning "=== Deployment completed with warnings ==="
        echo -e "${YELLOW}Check the website manually: http://$PI_HOST${NC}"
    fi
}

# Help function
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Frontend Build and Deploy Script"
    echo "Builds React frontend locally and deploys static files to Pi via rsync"
    echo ""
    echo "Usage: $0"
    echo ""
    echo "This script will:"
    echo "  1. Load environment variables from infrastructure/environments/.env.production"
    echo "  2. Build the frontend locally using npm"
    echo "  3. Deploy static files to Pi using rsync"
    echo "  4. Restart nginx on Pi"
    echo "  5. Verify the deployment"
    exit 0
fi

# Run main function
main "$@"