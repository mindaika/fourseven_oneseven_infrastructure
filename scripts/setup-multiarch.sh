#!/bin/bash
# setup-multiarch.sh - One-time setup for multi-architecture building
# Run this once on your Fedora machine to enable building for Pi

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PI_HOST="192.168.1.5"
PI_USER="pi"
REGISTRY_PORT="5000"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')] $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check Docker version
    if ! docker version >/dev/null 2>&1; then
        error "Docker is not running or not installed"
    fi
    
    # Check buildx availability
    if ! docker buildx version >/dev/null 2>&1; then
        error "Docker buildx is not available. Please update Docker to 19.03+ or install buildx plugin"
    fi
    
    # Check Pi connectivity
    if ! ping -c 1 "$PI_HOST" >/dev/null 2>&1; then
        error "Cannot reach Pi at $PI_HOST. Check network connectivity"
    fi
    
    # Check SSH access to Pi
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$PI_USER@$PI_HOST" true 2>/dev/null; then
        error "Cannot SSH to $PI_USER@$PI_HOST. Please set up SSH key authentication"
    fi
    
    log "✓ All prerequisites met"
}

# Setup buildx builder for multi-platform builds
setup_buildx() {
    log "Setting up buildx for multi-platform builds..."
    
    # Get the IP address for registry config
    LOCAL_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K[^ ]+')
    
    # Remove existing builder if it exists
    if docker buildx ls | grep -q "fourseven-multiarch"; then
        warn "Removing existing builder 'fourseven-multiarch'"
        docker buildx rm fourseven-multiarch || true
    fi
    
    # Create buildx config for insecure registry
    mkdir -p ~/.docker/buildx-config
    cat > ~/.docker/buildx-config/buildkitd.toml << EOF
[registry."${LOCAL_IP}:${REGISTRY_PORT}"]
  http = true
  insecure = true

[registry."localhost:${REGISTRY_PORT}"]
  http = true
  insecure = true
EOF
    
    log "Created BuildKit config for insecure registry"
    
    # Create new builder with container driver and registry config
    docker buildx create \
        --name fourseven-multiarch \
        --driver docker-container \
        --config ~/.docker/buildx-config/buildkitd.toml \
        --use
    
    # Bootstrap the builder (downloads BuildKit image)
    log "Bootstrapping builder..."
    docker buildx inspect fourseven-multiarch --bootstrap
    
    # Verify supported platforms
    log "Supported platforms:"
    docker buildx inspect fourseven-multiarch | grep "Platforms:" | cut -d: -f2
    
    log "✓ Buildx configured for multi-platform builds with insecure registry support"
}

# Setup local Docker registry
setup_local_registry() {
    log "Setting up local Docker registry..."
    
    # Get local IP address that will be used for registry
    LOCAL_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K[^ ]+')
    
    # Configure local Docker daemon to trust insecure registry
    log "Configuring Docker daemon for insecure registry..."
    
    # Create Docker daemon config directory if it doesn't exist
    sudo mkdir -p /etc/docker
    
    # Backup existing daemon.json if it exists
    if [ -f /etc/docker/daemon.json ]; then
        sudo cp /etc/docker/daemon.json "/etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)"
        log "✓ Backed up existing daemon.json"
    fi
    
    # Create or update daemon.json with insecure registry config
    echo "{
        \"insecure-registries\": [\"${LOCAL_IP}:${REGISTRY_PORT}\", \"localhost:${REGISTRY_PORT}\"]
    }" | sudo tee /etc/docker/daemon.json
    
    # Restart Docker daemon to pick up new config
    log "Restarting Docker daemon..."
    sudo systemctl restart docker
    
    # Wait for Docker to come back up
    sleep 5
    
    # Verify Docker is working
    if ! docker version >/dev/null 2>&1; then
        error "Docker failed to restart properly"
    fi
    
    log "✓ Docker daemon configured for insecure registry"
    
    # Check if registry is already running
    if docker ps --format "table {{.Names}}" | grep -q "fourseven-registry"; then
        warn "Registry 'fourseven-registry' already running"
        return 0
    fi
    
    # Remove any stopped registry container
    docker rm fourseven-registry 2>/dev/null || true
    
    # Start registry container
    docker run -d \
        --name fourseven-registry \
        --restart=always \
        -p "${REGISTRY_PORT}:5000" \
        registry:2
    
    # Wait for registry to be ready
    sleep 5
    
    # Test registry
    if curl -f "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
        log "✓ Local registry running on port ${REGISTRY_PORT}"
    else
        error "Failed to start local registry"
    fi
    
    # Test registry with IP address
    if curl -f "http://${LOCAL_IP}:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
        log "✓ Registry accessible via IP address ${LOCAL_IP}:${REGISTRY_PORT}"
    else
        warn "Registry may not be accessible via IP address"
    fi
}

# Configure Pi to trust local registry
configure_pi_registry() {
    log "Configuring Pi to trust local registry..."
    
    # Configure Pi to use local registry
    LOCAL_IP=$(ip route get "$PI_HOST" | grep -oP 'src \K[^ ]+')
    
    if [ -z "$LOCAL_IP" ]; then
        error "Could not determine local IP address for Pi communication"
    fi
    
    info "Using local IP: $LOCAL_IP"
    
    # Configure Pi Docker daemon to trust our insecure registry
    ssh "$PI_USER@$PI_HOST" "
        # Create Docker daemon config directory
        sudo mkdir -p /etc/docker
        
        # Backup existing daemon.json if it exists
        if [ -f /etc/docker/daemon.json ]; then
            sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)
        fi
        
        # Create daemon.json with insecure registry config
        echo '{
            \"insecure-registries\": [\"${LOCAL_IP}:${REGISTRY_PORT}\"]
        }' | sudo tee /etc/docker/daemon.json
        
        # Restart Docker daemon
        sudo systemctl restart docker
        
        # Wait for Docker to come back up
        sleep 5
        
        # Test Docker is working
        docker version >/dev/null
        
        # Test registry access
        if curl -f http://${LOCAL_IP}:${REGISTRY_PORT}/v2/ >/dev/null 2>&1; then
            echo 'Registry accessible from Pi'
        else
            echo 'Warning: Registry may not be accessible from Pi'
        fi
    "
    
    log "✓ Pi configured to trust registry at ${LOCAL_IP}:${REGISTRY_PORT}"
    
    # Save registry info for other scripts
    cat > "$PROJECT_ROOT/.multiarch-config" << EOF
REGISTRY_HOST=${LOCAL_IP}
REGISTRY_PORT=${REGISTRY_PORT}
PI_HOST=${PI_HOST}
PI_USER=${PI_USER}
EOF
    
    log "✓ Registry configuration saved to .multiarch-config"
}

# Test the complete setup
test_setup() {
    log "Testing multi-architecture setup..."
    
    # Source the config we just created
    source "$PROJECT_ROOT/.multiarch-config"
    
    # Check Pi architecture first
    log "Checking Pi architecture..."
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
                    PI_PLATFORMS="linux/arm64,linux/arm/v7"
                    log "Fallback: Using both ARM variants for aarch64 system"
                    ;;
                *)
                    error "Unsupported Pi architecture: $PI_ARCH"
                    ;;
            esac
            ;;
    esac
    
    PLATFORMS="linux/amd64,$PI_PLATFORMS"
    log "Building test image for platforms: $PLATFORMS"
    
    # Create a simple test Dockerfile
    mkdir -p /tmp/multiarch-test
    cat > /tmp/multiarch-test/Dockerfile << 'EOF'
FROM alpine:latest
RUN echo "Architecture: $(uname -m)" > /tmp/arch.txt
CMD ["cat", "/tmp/arch.txt"]
EOF
    
    cd /tmp/multiarch-test
    
    # Build and push test image with correct architecture
    docker buildx build \
        --platform "$PLATFORMS" \
        --tag "${REGISTRY_HOST}:${REGISTRY_PORT}/multiarch-test:latest" \
        --push \
        .
    
    # Test pulling on Pi
    ssh "$PI_USER@$PI_HOST" "
        # Pull and run the test image
        docker pull ${REGISTRY_HOST}:${REGISTRY_PORT}/multiarch-test:latest
        echo 'Running test container on Pi:'
        docker run --rm ${REGISTRY_HOST}:${REGISTRY_PORT}/multiarch-test:latest
    "
    
    # Cleanup test
    docker rmi "${REGISTRY_HOST}:${REGISTRY_PORT}/multiarch-test:latest" 2>/dev/null || true
    ssh "$PI_USER@$PI_HOST" "docker rmi ${REGISTRY_HOST}:${REGISTRY_PORT}/multiarch-test:latest 2>/dev/null || true"
    rm -rf /tmp/multiarch-test
    
    log "✓ Multi-architecture setup working correctly for Pi architecture: $PI_ARCH"
}

# Main execution
main() {
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${BLUE}   Fourseven Oneseven Multi-Arch Setup   ${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo ""
    
    info "This script will set up multi-architecture building for your project"
    info "Pi: $PI_USER@$PI_HOST"
    info "Registry port: $REGISTRY_PORT"
    echo ""
    
    read -p "Continue with setup? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Setup cancelled"
        exit 0
    fi
    
    check_prerequisites
    setup_buildx
    setup_local_registry
    configure_pi_registry
    test_setup
    
    echo ""
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}            Setup Complete!               ${NC}"
    echo -e "${GREEN}===========================================${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Use ${BLUE}./scripts/build-multiarch.sh${NC} to build images for Pi"
    echo "  2. Use ${BLUE}./scripts/deploy-to-pi.sh${NC} to deploy to Pi"
    echo "  3. Use ${BLUE}./scripts/build-and-deploy.sh${NC} for combined workflow"
    echo ""
    echo -e "${YELLOW}Registry Info:${NC}"
    source "$PROJECT_ROOT/.multiarch-config"
    echo "  Registry: ${REGISTRY_HOST}:${REGISTRY_PORT}"
    echo "  Config saved in: .multiarch-config"
    echo ""
}

# Handle script arguments
case "${1:-}" in
    "test")
        source "$PROJECT_ROOT/.multiarch-config" 2>/dev/null || error "Run setup first"
        test_setup
        ;;
    "clean")
        log "Cleaning up multi-arch setup..."
        docker buildx rm fourseven-multiarch 2>/dev/null || true
        docker stop fourseven-registry 2>/dev/null || true
        docker rm fourseven-registry 2>/dev/null || true
        rm -f "$PROJECT_ROOT/.multiarch-config"
        rm -rf ~/.docker/buildx-config
        log "✓ Cleanup complete"
        ;;
    *)
        main
        ;;
esac