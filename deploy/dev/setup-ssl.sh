#!/bin/bash

# SSL Certificate Setup Script for Frappe HRMS
# This script sets up Let's Encrypt SSL certificates using certbot

set -e

echo "=== SSL Certificate Setup for Frappe HRMS ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run with sudo: sudo bash setup-ssl.sh"
    exit 1
fi

# Try to detect domain from .env.remote
ENV_FILE="deploy/dev/.env.remote"
SITE_NAME=""
if [ -f "$ENV_FILE" ]; then
    SITE_NAME=$(grep -E '^SITE_NAME=' "$ENV_FILE" | cut -d= -f2 | tr -d '\r')
fi

# Fallback or Override
DOMAIN="${1:-${SITE_NAME:-dev-hrms.sahdiagnostics.com}}"

if [[ "$DOMAIN" == www.* ]]; then
  WWW_DOMAIN="$DOMAIN"
  BASE_DOMAIN="${DOMAIN#www.}"
else
  BASE_DOMAIN="$DOMAIN"
  WWW_DOMAIN="www.$DOMAIN"
fi

echo "Configuring SSL for:"
echo "  Domain: $DOMAIN"
echo "  WWW:    $WWW_DOMAIN"
echo ""

echo "This script will:"
echo "1. Install certbot if not already installed"
echo "2. Obtain SSL certificates for $DOMAIN and $WWW_DOMAIN"
echo "3. Configure automatic certificate renewal"
echo ""

# Install certbot if not present
if ! command -v certbot &> /dev/null; then
    echo "=== Installing certbot ==="
    apt-get update
    apt-get install -y certbot python3-certbot-nginx
    echo "✓ Certbot installed"
else
    echo "✓ Certbot already installed"
fi

# Create certbot webroot directory
echo "=== Creating webroot directory ==="
mkdir -p /var/www/certbot
chown www-data:www-data /var/www/certbot

# Check if certificates already exist
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "=== SSL certificates already exist ==="
    read -p "Do you want to renew them? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Renewing certificates..."
        certbot renew --nginx
        systemctl reload nginx
        echo "✅ Certificates renewed successfully!"
    else
        echo "Skipping renewal"
    fi
else
    echo "=== Obtaining new SSL certificates ==="
    echo "This will validate domain ownership and obtain certificates"
    echo ""
    
    # Obtain certificates
    certbot --nginx \
        -d $DOMAIN \
        -d $WWW_DOMAIN \
        --non-interactive \
        --agree-tos \
        --redirect \
        --email admin@sahdiagnostics.com
    
    echo "✅ SSL certificates obtained successfully!"
fi

# Set up automatic renewal
echo "=== Setting up automatic certificate renewal ==="

# Create renewal cron job
CRON_JOB="0 0,12 * * * /usr/bin/certbot renew --quiet --nginx && /usr/bin/systemctl reload nginx"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "certbot renew"; then
    echo "✓ Certbot renewal cron job already exists"
else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "✓ Certbot renewal cron job added"
fi

# Test nginx configuration
echo "=== Testing nginx configuration ==="
if nginx -t; then
    systemctl reload nginx
    echo "✓ Nginx reloaded successfully"
else
    echo "✗ Nginx configuration test failed"
    exit 1
fi

echo ""
echo "=== SSL Setup Complete! ==="
echo ""
echo "Your site is now accessible at:"
echo "  https://$DOMAIN"
echo "  https://$WWW_DOMAIN"
echo ""
echo "Certificates will automatically renew twice daily."
echo "Certificate expiration: $(openssl x509 -enddate -noout -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem | cut -d= -f2)"
echo ""
