#!/bin/bash
set -e

echo "=== Pre-build Validation ==="

# Get paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$BASE_DIR")"

echo "Project structure:"
echo "  Script: $SCRIPT_DIR"
echo "  Infrastructure: $BASE_DIR"
echo "  Project root: $PROJECT_ROOT"

# Check environment file
ENV_FILE="$BASE_DIR/environments/.env.production"
echo ""
echo "=== Environment Check ==="
if [ -f "$ENV_FILE" ]; then
    echo "✓ Environment file found: $ENV_FILE"
    echo "Available variables:"
    grep -E "^[A-Z_]+" "$ENV_FILE" | cut -d= -f1 | sort
    
    # Source and validate critical variables
    set -a
    source "$ENV_FILE"
    set +a
    
    missing_vars=()
    [ -z "$AUTH0_DOMAIN" ] && missing_vars+=("AUTH0_DOMAIN")
    [ -z "$AUTH0_CLIENT_ID" ] && missing_vars+=("AUTH0_CLIENT_ID") 
    [ -z "$AUTH0_AUDIENCE" ] && missing_vars+=("AUTH0_AUDIENCE")
    [ -z "$ANTHROPIC_API_KEY" ] && missing_vars+=("ANTHROPIC_API_KEY")
    [ -z "$OPENAI_API_KEY" ] && missing_vars+=("OPENAI_API_KEY")
    
    if [ ${#missing_vars[@]} -eq 0 ]; then
        echo "✓ All required environment variables are set"
    else
        echo "✗ Missing required variables:"
        printf "  %s\n" "${missing_vars[@]}"
    fi
else
    echo "✗ Environment file not found: $ENV_FILE"
    exit 1
fi

# Check repositories and Dockerfiles
echo ""
echo "=== Repository Check ==="

repos=("fourseven_oneseven_frontend" "jobify" "pixify")
for repo in "${repos[@]}"; do
    repo_path="$PROJECT_ROOT/$repo"
    if [ -d "$repo_path" ]; then
        echo "✓ Repository found: $repo"
        
        # Check for Dockerfile.prod
        if [ -f "$repo_path/Dockerfile.prod" ]; then
            echo "  ✓ Dockerfile.prod exists"
        else
            echo "  ✗ Dockerfile.prod missing"
        fi
        
        # Check specific requirements
        case $repo in
            "fourseven_oneseven_frontend")
                if [ -f "$repo_path/package.json" ]; then
                    echo "  ✓ package.json found"
                else
                    echo "  ✗ package.json missing"
                fi
                ;;
            "jobify"|"pixify")
                if [ -f "$repo_path/pyproject.toml" ]; then
                    echo "  ✓ pyproject.toml found"
                else
                    echo "  ✗ pyproject.toml missing"
                fi
                ;;
        esac
    else
        echo "✗ Repository not found: $repo_path"
    fi
done

# Check Docker and system resources
echo ""
echo "=== System Check ==="
echo "Platform: $(uname -m)"
echo "Docker version: $(docker --version)"

# Check available disk space
echo "Disk space:"
df -h / | tail -1 | awk '{print "  Root: " $4 " available (" $5 " used)"}'

# Check available memory
echo "Memory:"
free -h | grep '^Mem:' | awk '{print "  Total: " $2 ", Available: " $7}'

# Check if buildx is available
echo "Docker buildx:"
if docker buildx version >/dev/null 2>&1; then
    echo "  ✓ Docker buildx available"
    docker buildx ls | grep -v "^NAME" || echo "  No builders configured"
else
    echo "  ✗ Docker buildx not available"
fi

echo ""
echo "=== Validation Complete ==="
echo "Ready to run: ./scripts/rebuild-prod.sh"