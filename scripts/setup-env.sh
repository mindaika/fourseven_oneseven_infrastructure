#!/bin/bash
# setup-env.sh - Environment Setup Script
# This script distributes environment variables to all services

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$PROJECT_ROOT/environments"

# Default environment
ENVIRONMENT=${1:-development}

# Validate environment parameter
if [[ "$ENVIRONMENT" != "development" && "$ENVIRONMENT" != "production" ]]; then
    echo -e "${RED}Error: Environment must be 'development' or 'production'${NC}"
    echo "Usage: $0 [development|production]"
    exit 1
fi

echo -e "${BLUE}=== Environment Setup Script ===${NC}"
echo -e "${BLUE}Environment: ${YELLOW}$ENVIRONMENT${NC}"
echo -e "${BLUE}Project Root: ${YELLOW}$PROJECT_ROOT${NC}"

# Check if source environment file exists
SOURCE_ENV="$ENV_DIR/.env.$ENVIRONMENT"
if [[ ! -f "$SOURCE_ENV" ]]; then
    echo -e "${RED}Error: Source environment file not found: $SOURCE_ENV${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found source environment file${NC}"

# Function to extract environment variables for a specific service
extract_service_env() {
    local service_name="$1"
    local target_file="$2"
    
    echo -e "${BLUE}Setting up environment for $service_name...${NC}"
    
    # Create target directory if it doesn't exist
    mkdir -p "$(dirname "$target_file")"
    
    # Start with environment marker
    echo "# Auto-generated from $SOURCE_ENV" > "$target_file"
    echo "# Environment: $ENVIRONMENT" >> "$target_file"
    echo "# Generated: $(date)" >> "$target_file"
    echo "" >> "$target_file"
    
    case "$service_name" in
        "frontend")
            # Frontend only gets VITE_ prefixed variables and general config
            grep -E "^(VITE_|NODE_ENV)" "$SOURCE_ENV" >> "$target_file" || true
            ;;
        "jobify")
            # Jobify needs Anthropic API and Auth0 backend config
            grep -E "^(ANTHROPIC_API_KEY|AUTH0_|FLASK_)" "$SOURCE_ENV" | grep -v "^VITE_" >> "$target_file" || true
            ;;
        "pixify")
            # Pixify needs OpenAI API and Auth0 backend config
            grep -E "^(OPENAI_API_KEY|AUTH0_|FLASK_)" "$SOURCE_ENV" | grep -v "^VITE_" >> "$target_file" || true
            ;;
        "infrastructure")
            # Infrastructure gets everything for Docker Compose
            cat "$SOURCE_ENV" >> "$target_file"
            ;;
    esac
    
    echo -e "${GREEN}✓ Created $target_file${NC}"
}

# Function to validate required variables for each service
validate_service_env() {
    local service_name="$1"
    local env_file="$2"
    
    case "$service_name" in
        "frontend")
            required_vars=("VITE_AUTH0_DOMAIN" "VITE_AUTH0_CLIENT_ID" "VITE_AUTH0_AUDIENCE")
            ;;
        "jobify")
            required_vars=("ANTHROPIC_API_KEY" "AUTH0_DOMAIN" "FLASK_ENV")
            ;;
        "pixify")
            required_vars=("OPENAI_API_KEY" "AUTH0_DOMAIN" "FLASK_ENV")
            ;;
        "infrastructure")
            required_vars=("ANTHROPIC_API_KEY" "OPENAI_API_KEY" "AUTH0_DOMAIN")
            ;;
    esac
    
    echo -e "${BLUE}Validating $service_name environment...${NC}"
    
    for var in "${required_vars[@]}"; do
        if ! grep -q "^${var}=" "$env_file"; then
            echo -e "${RED}✗ Missing required variable: $var${NC}"
            return 1
        fi
    done
    
    echo -e "${GREEN}✓ All required variables present for $service_name${NC}"
}

# Create backup of existing .env files
backup_existing_env() {
    local backup_suffix=".backup.$(date +%Y%m%d_%H%M%S)"
    
    echo -e "${BLUE}Creating backups of existing .env files...${NC}"
    
    local env_files=(
        "$PROJECT_ROOT/fourseven_oneseven_frontend/.env"
        "$PROJECT_ROOT/jobify/.env"
        "$PROJECT_ROOT/pixify/.env"
        "$PROJECT_ROOT/.env"
    )
    
    for file in "${env_files[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "${file}${backup_suffix}"
            echo -e "${YELLOW}✓ Backed up: $file${NC}"
        fi
    done
}

# Main execution
main() {
    echo -e "${BLUE}Starting environment setup for $ENVIRONMENT...${NC}"
    
    # Create backup
    backup_existing_env
    
    # Extract and distribute environment variables
    extract_service_env "frontend" "$PROJECT_ROOT/fourseven_oneseven_frontend/.env"
    extract_service_env "jobify" "$PROJECT_ROOT/jobify/.env"
    extract_service_env "pixify" "$PROJECT_ROOT/pixify/.env"
    extract_service_env "infrastructure" "$PROJECT_ROOT/.env"
    
    # Validate each service environment
    validate_service_env "frontend" "$PROJECT_ROOT/fourseven_oneseven_frontend/.env"
    validate_service_env "jobify" "$PROJECT_ROOT/jobify/.env"
    validate_service_env "pixify" "$PROJECT_ROOT/pixify/.env"
    validate_service_env "infrastructure" "$PROJECT_ROOT/.env"
    
    echo -e "${GREEN}=== Environment setup completed successfully! ===${NC}"
    echo -e "${BLUE}Environment: ${YELLOW}$ENVIRONMENT${NC}"
    echo -e "${BLUE}Files created:${NC}"
    echo -e "  • Frontend: fourseven_oneseven_frontend/.env"
    echo -e "  • Jobify: jobify/.env"
    echo -e "  • Pixify: pixify/.env"
    echo -e "  • Infrastructure: .env"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "  1. Review the generated .env files"
    echo -e "  2. Update production API keys in .env.production"
    echo -e "  3. Run your build process"
    echo ""
}

# Check if running with source command for environment variable export
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being executed directly
    main "$@"
else
    # Script is being sourced
    echo -e "${BLUE}Environment variables available for current shell${NC}"
fi