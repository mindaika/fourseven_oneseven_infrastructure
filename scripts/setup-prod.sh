#!/bin/bash
# setup-prod.sh

# Error handling function
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Repository configurations
REPOS=(
  "git@github.com:mindaika/fourseven_oneseven_frontend.git"
  "git@github.com:mindaika/jobify.git"
  "git@github.com:mindaika/pixify.git"
  "git@github.com:mindaika/fourseven_oneseven_infrastructure.git"
)

# Base directory configuration
BASE_DIR="/opt/fourseven_oneseven"
INFRASTRUCTURE_DIR="$BASE_DIR/fourseven_oneseven_infrastructure"

# Ensure script is run as root or with sudo
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root or with sudo"
fi

# Create base directory
mkdir -p "$BASE_DIR"
cd "$BASE_DIR" || error_exit "Cannot change to $BASE_DIR"

# Clone/update repositories
for repo in "${REPOS[@]}"; do
  repo_name=$(basename "$repo" .git)
  
  if [ ! -d "$repo_name" ]; then
    echo "Cloning $repo_name..."
    git clone "$repo" || error_exit "Failed to clone $repo"
  else
    echo "Updating $repo_name..."
    (cd "$repo_name" && git pull) || error_exit "Failed to update $repo_name"
  fi
done

# Verify infrastructure directory exists
[ -d "$INFRASTRUCTURE_DIR" ] || error_exit "Infrastructure directory not found"

# Check for .env file
ENV_FILE="$INFRASTRUCTURE_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Creating .env file template..."
  cat > "$ENV_FILE" << EOL
# Anthropic API Key for Jobify
ANTHROPIC_API_KEY=your_anthropic_api_key_here

# OpenAI API Key for Pixify
OPENAI_API_KEY=your_openai_api_key_here

# Auth0 Credentials
AUTH0_DOMAIN=your_auth0_domain
AUTH0_CLIENT_ID=your_auth0_client_id
AUTH0_CLIENT_SECRET=your_auth0_client_secret

# Additional environment-specific configurations
NODE_ENV=production
FLASK_ENV=production
FLASK_DEBUG=0
EOL
  chmod 600 "$ENV_FILE"
  error_exit "Please edit $ENV_FILE with your actual credentials before proceeding"
fi

# Ensure Docker is installed
if ! command -v docker &> /dev/null; then
  echo "Docker not found. Installing Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
fi

# Ensure Docker Compose plugin is installed
if ! docker compose version &> /dev/null; then
  echo "Docker Compose plugin not found. Ensure you have Docker Desktop or the Docker Compose plugin installed."
  error_exit "Docker Compose is required"
fi

# Pull latest images and rebuild
echo "Pulling latest images and rebuilding containers..."
cd "$INFRASTRUCTURE_DIR" || error_exit "Cannot change to infrastructure directory"

# Build and start services
docker compose -f docker-compose.prod.yml --env-file .env pull
docker compose -f docker-compose.prod.yml --env-file .env up -d --build

# Cleanup old images
docker image prune -f

echo "Deployment complete!"

# Optional: Set up automatic updates
cat > /etc/cron.d/fourseven_oneseven_update << EOL
0 2 * * * root $BASE_DIR/setup-prod.sh >> /var/log/fourseven_oneseven_update.log 2>&1
EOL

echo "Automatic daily update cron job created."

exit 0