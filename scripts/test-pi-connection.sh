#!/bin/bash
# test-pi-connection.sh - Test connection and current Pi setup

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PI_USER="pi"
PI_HOST="piberry"  # Correct hostname for SSH

echo -e "${BLUE}=== Testing Pi Connection and Setup ===${NC}"

# Test basic connection
echo -e "${BLUE}Testing SSH connection...${NC}"
if ssh -o ConnectTimeout=10 "$PI_USER@$PI_HOST" "echo 'SSH connection successful'" 2>/dev/null; then
    echo -e "${GREEN}✓ SSH connection working${NC}"
else
    echo -e "${RED}✗ SSH connection failed${NC}"
    echo -e "${YELLOW}Try: ssh-copy-id $PI_USER@$PI_HOST${NC}"
    exit 1
fi

# Check Pi directory structure
echo -e "${BLUE}Checking Pi directory structure...${NC}"
ssh "$PI_USER@$PI_HOST" "
echo '=== Repository structure ==='
ls -la ~/fourseven_oneseven/

echo '=== Infrastructure docker directory ==='
ls -la ~/fourseven_oneseven/fourseven_oneseven_infrastructure/docker/

echo '=== Current containers ==='
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo '=== Docker compose in infrastructure ==='
cd ~/fourseven_oneseven/fourseven_oneseven_infrastructure/docker/
ls -la docker-compose*.yml
echo 'Working from: \$(pwd)'

echo '=== Testing compose command ==='
docker-compose -f docker-compose.prod.yml ps 2>/dev/null || echo 'prod compose not found, trying default...'
docker-compose ps 2>/dev/null || echo 'No active compose project found'
"

echo -e "${GREEN}✓ Pi connection test completed${NC}"
echo -e "${BLUE}Ready to proceed with deployment setup${NC}"