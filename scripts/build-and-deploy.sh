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
PI_PROJECT_DIR="/home/pi/fourseven_oneseven"
PI_DOCKER_DIR="$PI_PROJECT_DIR/fourseven_oneseven_infrastructure/docker"
PI_ENV_FILE="$PI_PROJECT_DIR/fourseven_oneseven_infrastructure/.env"

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

# Load environment variables for local build
load_environment() {
    if [[ ! -f "$ENV_FILE" ]]; then
        error_exit "Environment file not found: $ENV_FILE"
    fi
    
    log_info "Loading environment variables for build..."
    source "$ENV_FILE"
    
    # Validate required Auth0 variables for frontend build
    local required_vars=("VITE_AUTH0_DOMAIN" "VITE_AUTH0_CLIENT_ID" "VITE_AUTH0_AUDIENCE")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error_exit "Required environment variable not set: $var"
        fi
    done
    
    log_success "Environment loaded and validated"
}

# Ensure environment is set up on Pi for Docker operations
sync_environment_to_pi() {
    log_info "Ensuring environment is set up on Pi..."
    
    # Test Pi connectivity first
    if ! ssh -o ConnectTimeout=10 "$PI_USER@$PI_HOST" "echo 'Pi connection test'" >/dev/null 2>&1; then
        error_exit "Cannot connect to Pi at $PI_USER@$PI_HOST"
    fi
    
    # Check if the environment file exists on Pi
    if ssh "$PI_USER@$PI_HOST" "[[ -f '$PI_ENV_FILE' ]]"; then
        log_info "Environment file exists on Pi: $PI_ENV_FILE"
        
        # Check if it has the key variables to avoid warnings
        local has_required_vars=$(ssh "$PI_USER@$PI_HOST" "
            if [[ -f '$PI_ENV_FILE' ]]; then
                if grep -q '^ANTHROPIC_API_KEY=' '$PI_ENV_FILE' && 
                   grep -q '^AUTH0_DOMAIN=' '$PI_ENV_FILE'; then
                    echo 'yes'
                else
                    echo 'no'
                fi
            else
                echo 'no'
            fi
        ")
        
        if [[ "$has_required_vars" == "yes" ]]; then
            log_success "Environment file on Pi has required variables"
        else
            log_warning "Environment file on Pi is missing some required variables"
        fi
    else
        log_warning "Environment file missing on Pi: $PI_ENV_FILE"
        log_info "Creating minimal environment file on Pi..."
        
        # Create a minimal environment file with placeholders to prevent Docker warnings
        ssh "$PI_USER@$PI_HOST" "
            mkdir -p '$(dirname "$PI_ENV_FILE")'
            cat > '$PI_ENV_FILE' << 'EOF'
# Minimal environment file to prevent Docker Compose warnings
# Update these with real values for production use

# Anthropic API Key for Jobify
ANTHROPIC_API_KEY=placeholder_anthropic_key

# OpenAI API Key for Pixify  
OPENAI_API_KEY=placeholder_openai_key

# Auth0 Configuration
AUTH0_DOMAIN=placeholder.auth0.com
AUTH0_CLIENT_ID=placeholder_client_id
AUTH0_AUDIENCE=https://placeholder-api

# Environment
NODE_ENV=production
FLASK_ENV=production
FLASK_DEBUG=0
EOF
            chmod 600 '$PI_ENV_FILE'
        "
        log_warning "Created placeholder environment file on Pi"
        log_warning "Update $PI_ENV_FILE on Pi with real values for production use"
    fi
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
        if command -v yarn >/dev/null 2>&1; then
            yarn install --frozen-lockfile
        else
            npm ci
        fi
    fi
    
    # Clean previous build
    log_info "Cleaning previous build..."
    rm -rf dist/
    
    # Build with environment variables
    log_info "Building frontend (this may take a moment)..."
    export VITE_AUTH0_DOMAIN="$VITE_AUTH0_DOMAIN"
    export VITE_AUTH0_CLIENT_ID="$VITE_AUTH0_CLIENT_ID"
    export VITE_AUTH0_AUDIENCE="$VITE_AUTH0_AUDIENCE"
    export NODE_ENV=production
    
    if command -v yarn >/dev/null 2>&1; then
        yarn build
    else
        npm run build
    fi
    
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
    
    # Create static directory on Pi if it doesn't exist
    ssh "$PI_USER@$PI_HOST" "mkdir -p '$PI_STATIC_DIR'"
    
    # Backup current static files if they exist
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

# Restart nginx on Pi (with proper environment handling)
restart_nginx() {
    log_info "Restarting nginx on Pi..."
    
    ssh "$PI_USER@$PI_HOST" "
        cd '$PI_DOCKER_DIR'
        
        # Check if docker compose file exists
        if [[ ! -f 'docker-compose.prod.yml' ]]; then
            echo 'Error: docker-compose.prod.yml not found in $PI_DOCKER_DIR'
            exit 1
        fi
        
        # Use the environment file to avoid warnings
        if [[ -f '$PI_ENV_FILE' ]]; then
            echo 'Using environment file: $PI_ENV_FILE'
            ENV_FILE_FLAG='--env-file $PI_ENV_FILE'
        else
            echo 'Warning: No environment file found, Docker may show warnings'
            ENV_FILE_FLAG=''
        fi
        
        # Check if nginx container exists and is managed by docker compose
        if docker compose -f docker-compose.prod.yml \$ENV_FILE_FLAG ps nginx >/dev/null 2>&1; then
            echo 'Restarting nginx container...'
            
            # Restart nginx specifically (this only affects nginx, not other services)
            docker compose -f docker-compose.prod.yml \$ENV_FILE_FLAG restart nginx
            
            # Wait for container to be ready
            sleep 5
            
            # Check if nginx is running properly
            if docker compose -f docker-compose.prod.yml \$ENV_FILE_FLAG ps nginx | grep -q 'Up'; then
                echo 'Nginx restarted successfully'
                
                # Test if nginx is actually serving content
                if curl -s -o /dev/null -w '%{http_code}' http://localhost | grep -q '200\|302\|301'; then
                    echo 'Nginx is responding to requests'
                else
                    echo 'Warning: Nginx may not be serving content properly'
                fi
            else
                echo 'Warning: Nginx container may not be running properly'
                echo 'Container status:'
                docker compose -f docker-compose.prod.yml \$ENV_FILE_FLAG ps nginx
                echo 'Recent logs:'
                docker compose -f docker-compose.prod.yml \$ENV_FILE_FLAG logs nginx --tail=10
            fi
        else
            echo 'Nginx container not found or not managed by docker compose'
            echo 'Attempting to start nginx service...'
            
            # Try to start just nginx
            if docker compose -f docker-compose.prod.yml \$ENV_FILE_FLAG up -d nginx; then
                echo 'Nginx started successfully'
            else
                echo 'Error: Failed to start nginx'
                exit 1
            fi
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
        
        # Try external access first
        if curl -s -o /dev/null -w "%{http_code}" "http://$PI_HOST" | grep -q "200\|302\|301"; then
            log_success "✓ Website responding externally at http://$PI_HOST"
            return 0
        fi
        
        # If external fails, try internal access via SSH
        if ssh "$PI_USER@$PI_HOST" "curl -s -o /dev/null -w '%{http_code}' http://localhost" | grep -q "200\|302\|301"; then
            log_success "✓ Website responding locally on Pi"
            log_warning "External access may be blocked by firewall/router configuration"
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Website not responding, waiting 10 seconds..."
            sleep 10
        fi
        ((attempt++))
    done
    
    log_error "Website not responding after $max_attempts attempts"
    log_info "Manual checks:"
    log_info "  Internal: ssh $PI_USER@$PI_HOST 'curl -I http://localhost'"
    log_info "  External: curl -I http://$PI_HOST"
    log_info "  Docker: ssh $PI_USER@$PI_HOST 'cd $PI_DOCKER_DIR && docker compose -f docker-compose.prod.yml ps'"
    return 1
}

# Main execution
main() {
    log_info "Starting frontend build and deployment..."
    
    # Load environment variables for local build
    load_environment
    
    # Ensure environment is properly set up on Pi for Docker operations
    sync_environment_to_pi
    
    # Build frontend locally
    build_frontend
    
    # Deploy static files to Pi
    deploy_to_pi
    
    # Restart nginx with proper environment handling
    restart_nginx
    
    # Verify deployment worked
    if verify_deployment; then
        log_success "=== Deployment Successful! ==="
        echo -e "${GREEN}Local: http://$PI_HOST${NC}"
        echo -e "${GREEN}Production: https://garbanzo.monster${NC}"
        echo ""
        log_info "Next steps:"
        echo -e "  • Test the website functionality"
        echo -e "  • Update real API keys in $PI_ENV_FILE if using placeholders"
        echo -e "  • Check SSL certificate status if using HTTPS"
    else
        log_warning "=== Deployment completed with warnings ==="
        echo -e "${YELLOW}Check the website manually: http://$PI_HOST${NC}"
        echo -e "${YELLOW}Debug: ssh $PI_USER@$PI_HOST 'docker logs nginx'${NC}"
    fi
}

# Help function
show_help() {
    cat << EOF
Frontend Build and Deploy Script

DESCRIPTION:
    Builds React frontend locally and deploys static files to Pi via rsync.
    Handles environment variables properly for both build and deployment.

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --help    Show this help message

WORKFLOW:
    1. Load environment variables from infrastructure/environments/.env.production
    2. Ensure Pi has proper environment setup for Docker operations
    3. Build the frontend locally using yarn/npm
    4. Deploy static files to Pi using rsync
    5. Restart nginx on Pi with proper environment file handling
    6. Verify the deployment is working

REQUIREMENTS:
    - SSH access to Pi configured
    - Environment file with Auth0 credentials for build
    - Docker and Docker Compose running on Pi
    - Yarn or npm installed locally

TROUBLESHOOTING:
    - If you see Docker Compose warnings about missing variables:
      Update $PI_ENV_FILE on the Pi with real values
    - If website doesn't respond externally:
      Check firewall/router port forwarding for port 80/443

EOF
}

# Parse command line arguments
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

# Run main function
main "$@"