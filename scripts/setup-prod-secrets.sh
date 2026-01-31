#!/bin/bash
# Quick setup for file-based secrets in production

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="$INFRASTRUCTURE_DIR/secrets"

echo "=== Setting up file-based secrets ==="

# Create secrets directory
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

echo "Enter your production API keys:"
echo

# OpenAI
read -sp "OpenAI API Key: " OPENAI_KEY
echo
echo "$OPENAI_KEY" > "$SECRETS_DIR/openai_api_key.txt"
chmod 600 "$SECRETS_DIR/openai_api_key.txt"

# Anthropic
read -sp "Anthropic API Key: " ANTHROPIC_KEY
echo
echo "$ANTHROPIC_KEY" > "$SECRETS_DIR/anthropic_api_key.txt"
chmod 600 "$SECRETS_DIR/anthropic_api_key.txt"

echo
echo "✓ Secrets created in $SECRETS_DIR"
echo "✓ Permissions set to 600 (owner read/write only)"
echo
echo "Deploy with:"
echo "  docker compose -f docker/compose.yaml -f docker/compose.prod.yaml -f docker/compose.prod-secrets.yaml up -d"
