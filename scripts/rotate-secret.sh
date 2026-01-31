#!/bin/bash
# Rotate a Docker secret (remove old, create new, update services)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

STACK_NAME="fourseven_oneseven"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <secret_name>"
    echo ""
    echo "Available secrets:"
    docker secret ls --format '{{.Name}}'
    exit 1
fi

SECRET_NAME=$1

echo -e "${BLUE}=== Rotating Secret: ${SECRET_NAME} ===${NC}"

# Check if secret exists
if ! docker secret ls --format '{{.Name}}' | grep -q "^${SECRET_NAME}$"; then
    echo -e "${RED}✗ Secret '${SECRET_NAME}' does not exist${NC}"
    echo -e "${YELLOW}Available secrets:${NC}"
    docker secret ls
    exit 1
fi

# Get new secret value
echo -e "${BLUE}Enter new value for '${SECRET_NAME}'${NC}"
read -sp "New secret value: " NEW_VALUE
echo

if [ -z "$NEW_VALUE" ]; then
    echo -e "${RED}✗ Secret value cannot be empty${NC}"
    exit 1
fi

# Create new secret with timestamp suffix
NEW_SECRET_NAME="${SECRET_NAME}_$(date +%Y%m%d_%H%M%S)"
echo "$NEW_VALUE" | docker secret create "$NEW_SECRET_NAME" -
echo -e "${GREEN}✓ Created new secret: ${NEW_SECRET_NAME}${NC}"

# Find services using the old secret
SERVICES=$(docker service ls --filter "label=com.docker.stack.namespace=${STACK_NAME}" --format '{{.Name}}')

echo ""
echo -e "${BLUE}Updating services to use new secret...${NC}"

for SERVICE in $SERVICES; do
    # Check if service uses this secret
    if docker service inspect "$SERVICE" --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}' | grep -q "$SECRET_NAME"; then
        echo -e "${YELLOW}Updating service: $SERVICE${NC}"

        # Update service to use new secret
        docker service update \
            --secret-rm "$SECRET_NAME" \
            --secret-add "source=$NEW_SECRET_NAME,target=/run/secrets/$SECRET_NAME" \
            "$SERVICE"

        echo -e "${GREEN}✓ Updated $SERVICE${NC}"
    fi
done

echo ""
echo -e "${BLUE}Removing old secret...${NC}"
docker secret rm "$SECRET_NAME"
echo -e "${GREEN}✓ Old secret removed${NC}"

echo ""
echo -e "${BLUE}Renaming new secret...${NC}"
# We need to create the final secret and update services again
echo "$NEW_VALUE" | docker secret create "$SECRET_NAME" -

for SERVICE in $SERVICES; do
    if docker service inspect "$SERVICE" --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}' | grep -q "$NEW_SECRET_NAME"; then
        docker service update \
            --secret-rm "$NEW_SECRET_NAME" \
            --secret-add "source=$SECRET_NAME,target=/run/secrets/$SECRET_NAME" \
            "$SERVICE"
    fi
done

docker secret rm "$NEW_SECRET_NAME"

echo ""
echo -e "${GREEN}=== Secret Rotation Complete ===${NC}"
echo -e "Secret '${SECRET_NAME}' has been rotated and all services updated"
