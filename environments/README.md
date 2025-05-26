# Environment Management System

This directory contains the centralized environment management system for the fourseven_oneseven project.

## Overview

Instead of maintaining separate `.env` files across multiple repositories, all environment variables are centralized here and distributed to services as needed.

## File Structure

```
fourseven_oneseven_infrastructure/
├── environments/
│   ├── .env.development      # All development environment variables
│   ├── .env.production       # All production environment variables
│   ├── .env.example          # Template showing all available variables
│   └── README.md             # This file
└── scripts/
    ├── setup-env.sh          # Distributes env vars to all services
    └── deploy-env.sh          # Environment deployment script
```

## Environment Files

### `.env.development`
Contains all environment variables for local development:
- Development API keys
- Local service URLs
- Debug flags enabled
- Development Auth0 configuration

### `.env.production`
Contains all environment variables for production deployment:
- Production API keys
- Production domain URLs
- Debug flags disabled
- Production Auth0 configuration

### `.env.example`
Template file showing all available environment variables with descriptions.

## Usage

### 1. Initial Setup

```bash
# Navigate to the infrastructure directory
cd fourseven_oneseven_infrastructure

# Make the setup script executable
chmod +x scripts/setup-env.sh

# Set up development environment (default)
./scripts/setup-env.sh development

# Set up production environment
./scripts/setup-env.sh production
```

### 2. What the Script Does

The `setup-env.sh` script:
1. Creates backups of existing `.env` files
2. Extracts relevant variables for each service:
   - **Frontend**: Only `VITE_` prefixed variables
   - **Jobify**: Anthropic API key + Auth0 backend config
   - **Pixify**: OpenAI API key + Auth0 backend config
   - **Infrastructure**: All variables for Docker Compose
3. Validates that required variables are present
4. Creates service-specific `.env` files

### 3. Service-Specific Variables

#### Frontend (`fourseven_oneseven_frontend/.env`)
```bash
VITE_AUTH0_DOMAIN=dev-ri5v3y2kytm8kswf.us.auth0.com
VITE_AUTH0_CLIENT_ID=iamzOTLMSjcqrhrlRx904jwZwjvC3Sqk
VITE_AUTH0_AUDIENCE=jobify-dev
VITE_API_BASE_URL=http://localhost:8080
VITE_JOBIFY_URL=http://localhost:5004
VITE_PIXIFY_URL=http://localhost:5005
NODE_ENV=development
```

#### Jobify (`jobify/.env`)
```bash
ANTHROPIC_API_KEY=sk-ant-api03-...
AUTH0_DOMAIN=dev-ri5v3y2kytm8kswf.us.auth0.com
AUTH0_CLIENT_ID=iamzOTLMSjcqrhrlRx904jwZwjvC3Sqk
AUTH0_AUDIENCE=jobify-dev
AUTH0_CLIENT_SECRET=your_client_secret
FLASK_ENV=development
FLASK_DEBUG=1
```

#### Pixify (`pixify/.env`)
```bash
OPENAI_API_KEY=sk-svcacct-...
AUTH0_DOMAIN=dev-ri5v3y2kytm8kswf.us.auth0.com
AUTH0_CLIENT_ID=iamzOTLMSjcqrhrlRx904jwZwjvC3Sqk
AUTH0_AUDIENCE=jobify-dev
AUTH0_CLIENT_SECRET=your_client_secret
FLASK_ENV=development
FLASK_DEBUG=1
```

## Development Workflow

### 1. Making Environment Changes

1. Edit the appropriate central file (`.env.development` or `.env.production`)
2. Run the setup script to distribute changes:
   ```bash
   ./scripts/setup-env.sh development
   ```
3. Restart your services to pick up changes

### 2. Adding New Variables

1. Add the variable to both `.env.development` and `.env.production`
2. Update `.env.example` with documentation
3. Modify `setup-env.sh` if the variable should be distributed to specific services
4. Run the setup script

### 3. Production Deployment

Before deploying to production:

1. **Update production API keys** in `.env.production`:
   ```bash
   # Replace with actual production keys
   ANTHROPIC_API_KEY=your_production_anthropic_key
   OPENAI_API_KEY=your_production_openai_key
   ```

2. **Update Auth0 configuration** for production:
   ```bash
   AUTH0_DOMAIN=your-prod-domain.auth0.com
   AUTH0_CLIENT_ID=your_prod_client_id
   AUTH0_AUDIENCE=jobify-prod
   ```

3. **Set up production environment**:
   ```bash
   ./scripts/setup-env.sh production
   ```

## Security Best Practices

### ✅ Do's
- Keep production API keys separate from development keys
- Use the centralized system for all environment management
- Regularly rotate API keys
- Use different Auth0 applications for dev/prod

### ❌ Don'ts
- Never commit real API keys to git repositories
- Don't edit individual service `.env` files directly
- Don't share production keys in development
- Don't use the same Auth0 application for dev and prod

## Troubleshooting

### Missing Variables Error
If you get missing variable errors:
1. Check that the variable exists in the central `.env.{environment}` file
2. Verify the variable name matches exactly (case-sensitive)
3. Run the setup script again: `./scripts/setup-env.sh development`

### Service Can't Find Variables
1. Ensure the service's `.env` file was created by the setup script
2. Check that your application is reading from the correct `.env` file path
3. Restart the service after environment changes

### Production Deployment Issues
1. Verify all production API keys are valid
2. Check that production URLs are accessible
3. Ensure Auth0 production application is configured correctly

## Migration from Old System

If you're migrating from the old scattered `.env` files:

1. **Backup existing files**:
   ```bash
   find . -name ".env*" -exec cp {} {}.backup \;
   ```

2. **Run the setup script**:
   ```bash
   ./scripts/setup-env.sh development
   ```

3. **Verify everything works**:
   ```bash
   # Test each service starts correctly
   # Check environment variables are loaded
   ```

4. **Remove old backup files** (after confirming everything works):
   ```bash
   find . -name "*.backup" -delete
   ```