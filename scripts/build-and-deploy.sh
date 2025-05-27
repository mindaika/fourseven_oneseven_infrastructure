#!/bin/bash
# build-and-deploy.sh - Combined build and deploy workflow
# One command to build multi-arch images and deploy to Pi

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

# Default environment
ENVIRONMENT=${1:-production}

# Validate environment parameter
if [[ "$ENVIRONMENT" != "development" && "$ENVIRONMENT" != "production" ]]; then
    error "Environment must be 'development' or 'production'"
fi

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}    Fourseven Oneseven Build & Deploy     ${NC}"  
echo -e "${BLUE}============================================${NC}"
echo ""
info "Environment: $ENVIRONMENT"
info "This will build multi-arch images and deploy to Pi"
echo ""

# Confirmation for production
if [ "$ENVIRONMENT" = "production" ]; then
    read -p "Deploy to PRODUCTION? This will update the live site. (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Deployment cancelled"
        exit 0
    fi
fi

# Step 1: Build multi-architecture images
log "Phase 1: Building multi-architecture images..."
echo ""

if ! "$SCRIPT_DIR/build-multiarch.sh" "$ENVIRONMENT"; then
    error "Build phase failed"
fi

echo ""
log "✓ Build phase completed successfully"
echo ""

# Brief pause between phases
sleep 2

# Step 2: Deploy to Pi
log "Phase 2: Deploying to Pi..."
echo ""

if ! "$SCRIPT_DIR/deploy-to-pi.sh" "$ENVIRONMENT"; then
    error "Deploy phase failed"
fi

echo ""
log "✓ Deploy phase completed successfully"
echo ""

# Final summary
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}     Build & Deploy Complete!              ${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${YELLOW}Summary:${NC}"
echo "  ✓ Built multi-architecture images for linux/amd64 and linux/arm64"
echo "  ✓ Pushed images to local registry"
echo "  ✓ Deployed to Pi successfully"
echo "  ✓ Health checks passed"
echo ""

# Load config to show URLs
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
if [ -f "$PROJECT_ROOT/.multiarch-config" ]; then
    source "$PROJECT_ROOT/.multiarch-config"
    echo -e "${YELLOW}Your application is running at:${NC}"
    echo "  • Main site: ${BLUE}http://${PI_HOST}${NC}"
    echo "  • Jobify: ${BLUE}http://${PI_HOST}/jobify/${NC}"
    echo "  • Pixify: ${BLUE}http://${PI_HOST}/pixify/${NC}"
fi

echo ""
echo -e "${YELLOW}Quick commands:${NC}"
echo "  • Check status: ${BLUE}./scripts/deploy-to-pi.sh status${NC}"
echo "  • View logs: ${BLUE}./scripts/deploy-to-pi.sh logs${NC}"
echo "  • Re-deploy: ${BLUE}./scripts/build-and-deploy.sh $ENVIRONMENT${NC}"
echo ""