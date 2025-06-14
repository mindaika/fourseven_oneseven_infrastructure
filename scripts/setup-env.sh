#!/bin/bash
# setup-env.sh - Environment Setup Script for Separate Repositories
# This script distributes environment variables from the infrastructure repo to all service repos

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$INFRASTRUCTURE_ROOT")"
ENV_DIR="$INFRASTRUCTURE_ROOT/environments"

# Default environment
ENVIRONMENT=${1:-development}

# Repository paths - these are sibling directories to infrastructure
FRONTEND_REPO="$PROJECT_ROOT/fourseven_oneseven_frontend"
JOBIFY_REPO="$PROJECT_ROOT/jobify"
PIXIFY_REPO="$PROJECT_ROOT/pixify"

# Validate environment parameter
if [[ "$ENVIRONMENT" != "development" && "$ENVIRONMENT" != "production" ]]; then
    echo -e "${RED}Error: Environment must be 'development' or 'production'${NC}"
    echo "Usage: $0 [development|production]"
    exit 1
fi

echo -e "${BLUE}=== Environment Setup Script ===${NC}"
echo -e "${BLUE}Environment: ${YELLOW}$ENVIRONMENT${NC}"
echo -e "${BLUE}Infrastructure Root: ${YELLOW}$INFRASTRUCTURE_ROOT${NC}"
echo -e "${BLUE}Project Root: ${YELLOW}$PROJECT_ROOT${NC}"

# Check if source environment file exists
SOURCE_ENV="$ENV_DIR/.env.$ENVIRONMENT"
if [[ ! -f "$SOURCE_ENV" ]]; then
    echo -e "${RED}Error: Source environment file not found: $SOURCE_ENV${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found source environment file${NC}"

# Check if all repository directories exist
check_repo_exists() {
    local repo_name="$1"
    local repo_path="$2"
    
    if [[ ! -d "$repo_path" ]]; then
        echo -e "${YELLOW}Warning: $repo_name repository not found at $repo_path${NC}"
        echo -e "${YELLOW}Skipping $repo_name...${NC}"
        return 1
    fi
    return 0
}

# Function to extract environment variables for a specific service
extract_service_env() {
    local service_name="$1"
    local target_file="$2"
    
    # Check if repository exists - if not, skip entirely
    if ! check_repo_exists "$service_name" "$(dirname "$target_file")"; then
        return 0
    fi
    
    echo -e "${BLUE}Setting up environment for $service_name...${NC}"
    
    # Only create files in existing repositories - do NOT create directories
    if [[ ! -d "$(dirname "$target_file")" ]]; then
        echo -e "${RED}Error: Repository directory does not exist: $(dirname "$target_file")${NC}"
        return 1
    fi
    
    # Start with environment marker
    echo "# Auto-generated from $SOURCE_ENV" > "$target_file"
    echo "# Environment: $ENVIRONMENT" >> "$target_file"
    echo "# Generated: $(date)" >> "$target_file"
    echo "# " >> "$target_file"
    echo "# This file is automatically generated by the infrastructure repo" >> "$target_file"
    echo "# Do not edit directly - make changes in infrastructure/environments/.env.$ENVIRONMENT" >> "$target_file"
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
    esac
    
    echo -e "${GREEN}✓ Created $target_file${NC}"
}

# Function to validate required variables for each service
validate_service_env() {
    local service_name="$1"
    local env_file="$2"
    
    if [[ ! -f "$env_file" ]]; then
        echo -e "${YELLOW}Skipping validation for $service_name (file not created)${NC}"
        return 0
    fi
    
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
        "$FRONTEND_REPO/.env"
        "$JOBIFY_REPO/.env"
        "$PIXIFY_REPO/.env"
    )
    
    for file in "${env_files[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "${file}${backup_suffix}"
            echo -e "${YELLOW}✓ Backed up: $file${NC}"
            
            # Keep only the 3 most recent backups for this file
            local backup_pattern="${file}.backup.*"
            local backup_count=$(ls -1 ${backup_pattern} 2>/dev/null | wc -l)
            if [[ $backup_count -gt 3 ]]; then
                echo -e "${BLUE}  Cleaning old backups (keeping 3 most recent)...${NC}"
                ls -1t ${backup_pattern} 2>/dev/null | tail -n +4 | xargs rm -f
            fi
        fi
    done
}

# Function to show repository status
show_repo_status() {
    echo -e "${BLUE}Repository Status:${NC}"
    
    local repos=(
        "Frontend:$FRONTEND_REPO"
        "Jobify:$JOBIFY_REPO" 
        "Pixify:$PIXIFY_REPO"
        "Infrastructure:$INFRASTRUCTURE_ROOT"
    )
    
    for repo_info in "${repos[@]}"; do
        local name="${repo_info%%:*}"
        local path="${repo_info##*:}"
        
        if [[ -d "$path" ]]; then
            echo -e "  ${GREEN}✓${NC} $name: $path"
        else
            echo -e "  ${RED}✗${NC} $name: $path (not found)"
        fi
    done
    echo ""
}

# Main execution
main() {
    echo -e "${BLUE}Starting environment setup for $ENVIRONMENT...${NC}"
    
    # Show repository status
    show_repo_status
    
    # Create backup
    backup_existing_env
    
    # Extract and distribute environment variables
    extract_service_env "frontend" "$FRONTEND_REPO/.env"
    extract_service_env "jobify" "$JOBIFY_REPO/.env"
    extract_service_env "pixify" "$PIXIFY_REPO/.env"
    
    # Validate each service environment
    validate_service_env "frontend" "$FRONTEND_REPO/.env"
    validate_service_env "jobify" "$JOBIFY_REPO/.env"
    validate_service_env "pixify" "$PIXIFY_REPO/.env"
    
    echo -e "${GREEN}=== Environment setup completed successfully! ===${NC}"
    echo -e "${BLUE}Environment: ${YELLOW}$ENVIRONMENT${NC}"
    echo -e "${BLUE}Files created:${NC}"
    
    if [[ -f "$FRONTEND_REPO/.env" ]]; then
        echo -e "  • Frontend: $FRONTEND_REPO/.env"
    fi
    if [[ -f "$JOBIFY_REPO/.env" ]]; then
        echo -e "  • Jobify: $JOBIFY_REPO/.env"
    fi
    if [[ -f "$PIXIFY_REPO/.env" ]]; then
        echo -e "  • Pixify: $PIXIFY_REPO/.env"
    fi
    
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "  1. Review the generated .env files in each repository"
    echo -e "  2. Update production API keys in environments/.env.production"
    echo -e "  3. Run your build process"
    echo -e "  4. Test each service with the new environment setup"
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