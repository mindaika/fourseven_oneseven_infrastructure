#!/bin/bash
# Deploy application stack using Docker Swarm with secrets

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$INFRASTRUCTURE_DIR/docker"
STACK_NAME="fourseven_oneseven"
ENV_FILE="$INFRASTRUCTURE_DIR/environments/.env.production"

echo -e "${BLUE}=== Deploy with Docker Secrets ===${NC}"

# Check if in swarm mode
if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo -e "${RED}✗ Docker Swarm is not initialized${NC}"
    echo -e "${YELLOW}Run ./scripts/init-swarm.sh first${NC}"
    exit 1
fi

# Check if secrets exist
REQUIRED_SECRETS=("openai_api_key" "anthropic_api_key")
MISSING_SECRETS=()

for secret in "${REQUIRED_SECRETS[@]}"; do
    if ! docker secret ls --format '{{.Name}}' | grep -q "^${secret}$"; then
        MISSING_SECRETS+=("$secret")
    fi
done

if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
    echo -e "${RED}✗ Missing required secrets:${NC}"
    for secret in "${MISSING_SECRETS[@]}"; do
        echo -e "  - $secret"
    done
    echo -e "${YELLOW}Run ./scripts/init-swarm.sh to create secrets${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All required secrets found${NC}"

# Load environment variables for non-secret config
if [ -f "$ENV_FILE" ]; then
    echo -e "${BLUE}Loading environment from: $ENV_FILE${NC}"
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo -e "${YELLOW}Warning: Environment file not found: $ENV_FILE${NC}"
    echo -e "${YELLOW}Using defaults...${NC}"
fi

# Deploy the stack
echo ""
echo -e "${BLUE}Deploying stack: $STACK_NAME${NC}"
cd "$DOCKER_DIR"

# Check which compose file to use
if [ -f "compose.secrets-example.yaml" ]; then
    COMPOSE_FILE="compose.secrets-example.yaml"
    echo -e "${BLUE}Using secrets-enabled compose file${NC}"
else
    echo -e "${RED}✗ compose.secrets-example.yaml not found${NC}"
    exit 1
fi

docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME"

echo ""
echo -e "${GREEN}✓ Stack deployed${NC}"

# Wait a moment for services to start
sleep 3

# Show status
echo ""
echo -e "${BLUE}=== Stack Status ===${NC}"
docker stack ps "$STACK_NAME" --no-trunc

echo ""
echo -e "${BLUE}=== Services ===${NC}"
docker stack services "$STACK_NAME"

echo ""
echo -e "${BLUE}=== Useful Commands ===${NC}"
echo -e "View logs:        ${GREEN}docker service logs ${STACK_NAME}_pixify -f${NC}"
echo -e "Scale service:    ${GREEN}docker service scale ${STACK_NAME}_pixify=3${NC}"
echo -e "Update service:   ${GREEN}docker service update --force ${STACK_NAME}_pixify${NC}"
echo -e "Remove stack:     ${GREEN}docker stack rm ${STACK_NAME}${NC}"
echo -e "Service details:  ${GREEN}docker service inspect ${STACK_NAME}_pixify${NC}"
