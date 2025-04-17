#!/bin/bash

DOMAIN="garbanzo.monster"
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
DAYS_THRESHOLD=30
INFRASTRUCTURE_DIR="$HOME/fourseven_oneseven/fourseven_oneseven_infrastructure"
NGINX_DIR="$INFRASTRUCTURE_DIR/nginx"
REBUILD_SCRIPT="/home/pi/fourseven_oneseven/fourseven_oneseven_infrastructure
/scripts/rebuild-prod.sh"

if [ -f "$CERT_PATH" ]; then
    expiry_date=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
    expiry_epoch=$(date -d "$expiry_date" +%s)
    current_epoch=$(date +%s)
    days_left=$(( ($expiry_epoch - $current_epoch) / 86400 ))

    echo "Certificate for $DOMAIN has $days_left days remaining."

    if [ $days_left -lt $DAYS_THRESHOLD ]; then
        echo "Certificate for $DOMAIN will expire in $days_left days. Attempting renewal..."
        sudo certbot renew --quiet
        renewal_result=$?
        
        if [ $renewal_result -eq 0 ]; then
            echo "Certificate renewal successful. Copying certificates..."
            # Copy renewed certificates
            sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $NGINX_DIR/ssl/
            sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $NGINX_DIR/ssl/
            sudo chown -R $USER:$USER $NGINX_DIR/ssl
            chmod 600 $NGINX_DIR/ssl/*.pem
            
            echo "Rebuilding website with new certificates..."
            # Call the rebuild script with sudo
            sudo $REBUILD_SCRIPT
            
            echo "Website rebuilt successfully with new certificates."
        else
            echo "Certificate renewal failed with exit code $renewal_result."
        fi
    else
        echo "Certificate for $DOMAIN is valid for $days_left days. No action needed."
    fi
else
    echo "Certificate file not found. Please ensure certbot is installed and certificates are generated."
fi