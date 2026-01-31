#!/bin/bash
# Quick setup script for local development
# Creates a basic .env.development file if it doesn't exist

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$INFRASTRUCTURE_DIR/environments"
DEV_ENV="$ENV_DIR/.env.development"
EXAMPLE_ENV="$ENV_DIR/.env.example"

echo "=== Quick Development Setup ==="
echo

# Check if .env.development already exists
if [ -f "$DEV_ENV" ]; then
    echo "✓ Environment file already exists: $DEV_ENV"
    echo
    read -p "Overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Keeping existing environment file."
        echo "Running setup to distribute variables..."
        cd "$INFRASTRUCTURE_DIR"
        ./scripts/setup-env.sh development
        exit 0
    fi
    # Backup existing file
    cp "$DEV_ENV" "${DEV_ENV}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "Created backup of existing file"
fi

# Copy example to create development environment
if [ ! -f "$EXAMPLE_ENV" ]; then
    echo "ERROR: Example environment file not found: $EXAMPLE_ENV"
    exit 1
fi

echo "Creating development environment file..."
cp "$EXAMPLE_ENV" "$DEV_ENV"

# Set development-specific defaults
sed -i 's/FLASK_ENV=production/FLASK_ENV=development/' "$DEV_ENV"
sed -i 's/FLASK_DEBUG=0/FLASK_DEBUG=1/' "$DEV_ENV"
sed -i 's/NODE_ENV=production/NODE_ENV=development/' "$DEV_ENV"

echo "✓ Created $DEV_ENV"
echo

# Prompt for API keys
echo "=== API Keys Setup ==="
echo "You can set these now or edit $DEV_ENV later."
echo

read -p "Do you want to enter API keys now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # OpenAI API Key
    read -p "OpenAI API Key (press Enter to skip): " openai_key
    if [ -n "$openai_key" ]; then
        sed -i "s|OPENAI_API_KEY=.*|OPENAI_API_KEY=$openai_key|" "$DEV_ENV"
        echo "✓ OpenAI API key set"
    fi

    # Anthropic API Key
    read -p "Anthropic API Key (press Enter to skip): " anthropic_key
    if [ -n "$anthropic_key" ]; then
        sed -i "s|ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=$anthropic_key|" "$DEV_ENV"
        echo "✓ Anthropic API key set"
    fi
fi

echo
echo "=== Distributing Environment Variables ==="
cd "$INFRASTRUCTURE_DIR"
./scripts/setup-env.sh development

echo
echo "=== Setup Complete! ==="
echo
echo "Next steps:"
echo "  1. Review and edit if needed: $DEV_ENV"
echo "  2. Start development: ./scripts/rebuild-dev.sh"
echo
echo "Note: API keys in .env files are less secure than Docker secrets."
echo "For production, consider using: ./scripts/init-swarm.sh"
