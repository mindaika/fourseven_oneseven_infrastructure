#!/bin/bash
# Restart specific service or all services

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <service>"
    echo ""
    echo "Services:"
    echo "  all           - Restart everything"
    echo "  infra         - Restart infrastructure (postgres, pihole, nginx)"
    echo "  apps          - Restart applications (jobify, pixify)"
    echo "  ha            - Restart Home Assistant"
    echo "  <container>   - Restart specific container"
    exit 1
fi

case "$1" in
    all)
        echo "🔄 Restarting all services..."
        ~/Source/fourseven_oneseven_infrastructure/scripts/stop.sh
        ~/Source/fourseven_oneseven_infrastructure/scripts/start.sh
        ;;
    infra)
        echo "🔄 Restarting infrastructure..."
        cd ~/Source/fourseven_oneseven_infrastructure/infrastructure && docker compose restart
        ;;
    apps)
        echo "🔄 Restarting applications..."
        cd ~/Source/fourseven_oneseven_infrastructure/apps && docker compose restart
        ;;
    ha)
        echo "🔄 Restarting Home Assistant..."
        cd ~/Source/fourseven_oneseven_infrastructure/homeassistant && docker compose restart
        ;;
    *)
        echo "🔄 Restarting container: $1"
        docker restart "$1"
        ;;
esac

echo "✅ Restart complete!"
