#!/bin/bash
# build-multiarch.sh - Build multi-architecture images for Pi deployment
# This replaces rebuild-dev.sh when you want to deploy to Pi

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
ENVIRONMENT=${1:-development}

# Validate environment parameter
if [[ "$ENVIRONMENT" != "development" && "$ENVIRONMENT" != "production" ]]; then
    error "Environment must be 'development' or 'production'"
fi

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}   Building Multi-Architecture Images   ${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
info "Environment: $ENVIRONMENT"
info "Registry: ${REGISTRY_HOST}:${REGISTRY_PORT}"
info "Target: Pi at $PI_HOST"
echo ""

cd "$INFRASTRUCTURE_ROOT"

# Check if environment file exists
ENV_FILE="./environments/.env.$ENVIRONMENT"
if [ ! -f "$ENV_FILE" ]; then
    error "Environment file not found: $ENV_FILE"
fi

# Ensure buildx builder is active
if ! docker buildx ls | grep -q "fourseven-multiarch.*\\*"; then
    log "Activating buildx builder..."
    docker buildx use fourseven-multiarch
fi

# Check if registry is running
if ! curl -f "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    error "Local registry not running. Run ./scripts/setup-multiarch.sh first"
fi

# Build frontend first (creates static files)
build_frontend() {
    log "Building frontend..."
    
    cd "$PROJECT_ROOT/fourseven_oneseven_frontend"
    
    # Install dependencies and build
    if [ ! -d "node_modules" ]; then
        log "Installing frontend dependencies..."
        yarn install
    fi
    
    log "Building frontend assets..."
    yarn build
    
    # Create nginx Dockerfile that includes built assets
    cat > Dockerfile.multiarch << 'EOF'
FROM nginx:alpine

# Copy built static files
COPY dist/ /usr/share/nginx/html/

# Copy nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
EOF

    # Build and push nginx image with static files
    log "Building and pushing nginx+frontend image..."
    docker buildx build \
        --platform "$BUILD_PLATFORMS" \
        --tag "${REGISTRY_HOST}:${REGISTRY_PORT}/fourseven_oneseven_nginx:latest" \
        --push \
        -f Dockerfile.multiarch \
        .
    
    # Clean up
    rm -f Dockerfile.multiarch
    
    log "✓ Frontend image built and pushed"
    cd "$INFRASTRUCTURE_ROOT"
}

# Build Flask applications
build_flask_app() {
    local app_name=$1
    log "Building $app_name..."
    
    cd "$PROJECT_ROOT/$app_name"
    
    # Determine which Dockerfile to use
    local dockerfile="Dockerfile"
    if [ "$ENVIRONMENT" = "production" ] && [ -f "Dockerfile.prod" ]; then
        dockerfile="Dockerfile.prod"
    fi
    
    if [ ! -f "$dockerfile" ]; then
        error "Dockerfile not found: $PROJECT_ROOT/$app_name/$dockerfile"
    fi
    
    # Build and push multi-arch image
    log "Building and pushing $app_name image..."
    docker buildx build \
        --platform "$BUILD_PLATFORMS" \
        --tag "${REGISTRY_HOST}:${REGISTRY_PORT}/fourseven_oneseven_${app_name}:latest" \
        --push \
        -f "$dockerfile" \
        .
    
    log "✓ $app_name image built and pushed"
    cd "$INFRASTRUCTURE_ROOT"
}

# Create docker-compose override for registry images
create_registry_compose() {
    log "Creating registry-based compose configuration..."
    
    local compose_override="docker/docker-compose.registry.yml"
    
    cat > "$compose_override" << EOF
# Auto-generated compose override for registry images
# This file overrides build contexts with pre-built images from registry

services:
  nginx:
    image: ${REGISTRY_HOST}:${REGISTRY_PORT}/fourseven_oneseven_nginx:latest

  jobify:
    image: ${REGISTRY_HOST}:${REGISTRY_PORT}/fourseven_oneseven_jobify:latest

  pixify:
    image: ${REGISTRY_HOST}:${REGISTRY_PORT}/fourseven_oneseven_pixify:latest
EOF

    log "✓ Registry compose override created: $compose_override"
}

# Main build process
main() {
    # Run environment setup to ensure .env files are current
    log "Setting up environment..."
    "$SCRIPT_DIR/setup-env.sh" "$ENVIRONMENT"
    
    # Detect Pi architecture and Docker preference
    log "Detecting Pi architecture..."
    PI_ARCH=$(ssh "$PI_USER@$PI_HOST" "uname -m")
    DOCKER_ARCH=$(ssh "$PI_USER@$PI_HOST" "docker version --format '{{.Server.Arch}}' 2>/dev/null || echo 'unknown'")
    
    log "Pi system architecture: $PI_ARCH" 
    log "Pi Docker architecture: $DOCKER_ARCH"
    
    # Use Docker's reported architecture as the primary guide
    case "$DOCKER_ARCH" in
        "arm"|"armv7")
            PI_PLATFORMS="linux/arm/v7"
            log "Docker requests 32-bit ARM images"
            ;;
        "arm64"|"aarch64")
            PI_PLATFORMS="linux/arm64"
            log "Docker requests 64-bit ARM images"
            ;;
        *)
            # Fallback to system architecture
            case "$PI_ARCH" in
                "armv7l"|"armv6l")
                    PI_PLATFORMS="linux/arm/v7"
                    log "Fallback: Using 32-bit ARM based on system architecture"
                    ;;
                "aarch64")
                    PI_PLATFORMS="linux/arm/v7"  # Since Docker reported 'arm'
                    log "Fallback: Using 32-bit ARM for aarch64 system (Docker compatibility)"
                    ;;
                *)
                    error "Unsupported Pi architecture: $PI_ARCH"
                    ;;
            esac
            ;;
    esac
    
    BUILD_PLATFORMS="linux/amd64,$PI_PLATFORMS"
    log "Building for platforms: $BUILD_PLATFORMS"
    
    # Build all components
    build_frontend
    build_flask_app "jobify"
    build_flask_app "pixify" 
    
    # Create compose override for registry
    create_registry_compose
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}         Build Complete!                ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo -e "${YELLOW}Images built for platforms:${NC} $BUILD_PLATFORMS"
    echo -e "${YELLOW}Pi architecture detected:${NC} $PI_ARCH"
    echo -e "${YELLOW}Registry:${NC} ${REGISTRY_HOST}:${REGISTRY_PORT}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  • Deploy to Pi: ${BLUE}./scripts/deploy-to-pi.sh $ENVIRONMENT${NC}"
    echo "  • Or test locally: ${BLUE}./scripts/rebuild-dev.sh${NC}"
    echo ""
    echo -e "${YELLOW}Built images:${NC}"
    echo "  • ${REGISTRY_HOST}:${REGISTRY_PORT}/fourseven_oneseven_nginx:latest"
    echo "  • ${REGISTRY_HOST}:${REGISTRY_PORT}/fourseven_oneseven_jobify:latest" 
    echo "  • ${REGISTRY_HOST}:${REGISTRY_PORT}/fourseven_oneseven_pixify:latest"
}

# Handle script arguments
case "${1:-development}" in
    "development"|"production")
        main
        ;;
    "clean")
        log "Cleaning build artifacts..."
        rm -f "$INFRASTRUCTURE_ROOT/docker/docker-compose.registry.yml"
        log "✓ Cleanup complete"
        ;;
    *)
        echo "Usage: $0 [development|production|clean]"
        echo "  development - Build images for development (default)"
        echo "  production  - Build images for production"
        echo "  clean       - Remove build artifacts"
        exit 1
        ;;
esac