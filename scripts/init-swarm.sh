#!/bin/bash
# Initialize Docker Swarm and create secrets for production deployment

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Docker Swarm Initialization ===${NC}"

# Check if already in swarm mode
if docker info 2>/dev/null | grep -q "Swarm: active"; then
    echo -e "${GREEN}✓ Docker Swarm is already initialized${NC}"
else
    echo -e "${YELLOW}Initializing Docker Swarm...${NC}"
    docker swarm init
    echo -e "${GREEN}✓ Docker Swarm initialized${NC}"
fi

echo ""
echo -e "${BLUE}=== Creating Secrets ===${NC}"
echo ""
echo -e "${YELLOW}Note: Secrets are immutable once created. If you need to update a secret,${NC}"
echo -e "${YELLOW}you must remove the old one and create a new one.${NC}"
echo ""

# Function to create or update a secret
create_secret() {
    local secret_name=$1
    local prompt_text=$2

    if docker secret ls --format '{{.Name}}' | grep -q "^${secret_name}$"; then
        echo -e "${YELLOW}Secret '${secret_name}' already exists${NC}"
        read -p "Do you want to replace it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Removing old secret..."
            docker secret rm "$secret_name" || echo "Could not remove secret (may be in use by services)"
        else
            echo "Skipping $secret_name"
            return
        fi
    fi

    echo -e "${BLUE}Creating secret: ${secret_name}${NC}"
    read -sp "${prompt_text}: " secret_value
    echo

    if [ -z "$secret_value" ]; then
        echo -e "${RED}✗ Secret value cannot be empty, skipping${NC}"
        return
    fi

    echo "$secret_value" | docker secret create "$secret_name" -
    echo -e "${GREEN}✓ Secret '${secret_name}' created${NC}"
    echo
}

# Create secrets
create_secret "openai_api_key" "Enter OpenAI API key"
create_secret "anthropic_api_key" "Enter Anthropic API key"
create_secret "auth0_client_secret" "Enter Auth0 Client Secret (optional, press Enter to skip)"

echo ""
echo -e "${GREEN}=== Secrets Created ===${NC}"
docker secret ls

echo ""
echo -e "${BLUE}=== Next Steps ===${NC}"
echo -e "1. Deploy your stack using:"
echo -e "   ${GREEN}docker stack deploy -c docker/compose.secrets-example.yaml fourseven_oneseven${NC}"
echo ""
echo -e "2. Or if using the regular compose file with docker compose:"
echo -e "   ${YELLOW}Note: 'docker compose' doesn't support Swarm secrets directly${NC}"
echo -e "   ${YELLOW}Use 'docker stack deploy' for Swarm mode deployments${NC}"
echo ""
echo -e "3. Check deployment status:"
echo -e "   ${GREEN}docker stack ps fourseven_oneseven${NC}"
echo ""
echo -e "4. View service logs:"
echo -e "   ${GREEN}docker service logs fourseven_oneseven_pixify${NC}"
