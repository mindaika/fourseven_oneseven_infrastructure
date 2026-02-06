#!/bin/bash
# View logs for services

if [ -z "$1" ]; then
    echo "Usage: $0 <service> [options]"
    echo ""
    echo "Services:"
    echo "  infra         - Infrastructure logs"
    echo "  apps          - Application logs"
    echo "  ha            - Home Assistant logs"
    echo "  <container>   - Specific container logs"
    echo ""
    echo "Options:"
    echo "  -f            - Follow logs (tail -f style)"
    echo ""
    echo "Examples:"
    echo "  $0 infra -f   - Follow all infrastructure logs"
    echo "  $0 nginx      - Show nginx logs"
    exit 1
fi

case "$1" in
    infra)
        cd ~/Source/fourseven_oneseven_infrastructure/infrastructure && docker compose logs "${@:2}"
        ;;
    apps)
        cd ~/Source/fourseven_oneseven_infrastructure/apps && docker compose logs "${@:2}"
        ;;
    ha)
        cd ~/Source/fourseven_oneseven_infrastructure/homeassistant && docker compose logs "${@:2}"
        ;;
    *)
        docker logs "$@"
        ;;
esac
