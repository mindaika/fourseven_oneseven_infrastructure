#!/bin/bash
# cleanup-project.sh - Remove only clearly unnecessary files

echo "=== CONSERVATIVE PROJECT CLEANUP ==="
echo "This will only remove backup files and macOS artifacts"
echo "Press Ctrl+C to cancel, Enter to continue"
read

# 1. Remove .env backup files (automated backups only)
echo "Removing .env backup files..."
find . -name ".env.backup.*" -type f -delete

# 2. Remove .DS_Store files (macOS artifacts)  
echo "Removing .DS_Store files..."
find . -name ".DS_Store" -type f -delete

# 3. Remove duplicate default.prod.conf in frontend (since they're identical)
echo "Removing duplicate default.prod.conf from frontend..."
rm -f fourseven_oneseven_frontend/default.prod.conf
echo "Kept fourseven_oneseven_frontend/nginx.conf (different - for development)"
echo "Kept fourseven_oneseven_infrastructure/nginx/conf.d/default.prod.conf (for production)"

# 4. Remove .multiarch-config if it's a temporary file
if [ -f .multiarch-config ]; then
    echo "Found .multiarch-config - is this a temporary buildx file? (y/n)"
    read -p "Remove it? " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm .multiarch-config
        echo "Removed .multiarch-config"
    fi
fi

echo "=== CLEANUP COMPLETE ==="
echo "Removed:"
echo "- .env backup files (automated backups)"
echo "- .DS_Store files (macOS artifacts)" 
echo "- Duplicate default.prod.conf from frontend"
echo "- .multiarch-config (if confirmed)"

echo -e "\n=== ALL IMPORTANT FILES PRESERVED ==="
echo "- All docker-compose files (base, dev, prod, registry)"
echo "- All environment templates and active .env files"
echo "- All scripts (build, deploy, setup, rebuild-dev, etc.)"
echo "- All test files and source code"
echo "- Both nginx configs (dev and prod serve different purposes)"
echo "- VS Code settings"