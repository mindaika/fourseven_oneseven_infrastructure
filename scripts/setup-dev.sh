#!/bin/bash
# setup-dev.sh

# Repository configurations
REPOS=(
  "git@github.com:mindaika/fourseven_oneseven_frontend.git"
  "git@github.com:mindaika/jobify.git"
  "git@github.com:mindaika/pixify.git"
)

# Create parent directory for all repos
PARENT_DIR="../fourseven_oneseven"
mkdir -p $PARENT_DIR
cd $PARENT_DIR

# Clone/pull all repositories
for repo in "${REPOS[@]}"; do
  repo_name=$(basename $repo .git)
  if [ ! -d "$repo_name" ]; then
    echo "Cloning $repo_name..."
    git clone $repo
  else
    echo "Updating $repo_name..."
    (cd $repo_name && git pull)
  fi
done

# Check for required API keys
if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env file - please update with your API keys and settings"
  echo "Required: ANTHROPIC_API_KEY (for Jobify)"
  echo "Required: OPENAI_API_KEY (for Pixify)"
  echo "Required: Auth0 credentials"
  exit 1
fi

# Start development environment
docker-compose -f docker-compose.yml -f docker-compose.dev.yml up