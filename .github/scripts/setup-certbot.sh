#!/bin/bash
set -e

# setup-certbot.sh
# Purpose: Obtain and configure SSL certificate with Certbot
# Arguments:
#   $1 - CERTBOT_DOMAIN
#   $2 - CERTBOT_EMAIL
#   $3 - lightsail_user
#   $4 - lightsail_host
#   $5 - lightsail_port
#   $6 - ssh_key_path

# Display help if arguments are missing
if [ $# -lt 5 ]; then
    echo "Usage: $0 <CERTBOT_DOMAIN> <CERTBOT_EMAIL> <lightsail_user> <lightsail_host> <lightsail_port> [ssh_key_path]"
    echo "Purpose: Obtain and configure SSL certificate with Certbot"
    exit 1
fi

CERTBOT_DOMAIN="$1"
CERTBOT_EMAIL="$2"
LIGHTSAIL_USER="$3"
LIGHTSAIL_HOST="$4"
LIGHTSAIL_PORT="$5"
SSH_KEY_PATH="${6:-~/.ssh/lightsail_key}"

# Expand ~ to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Setting up SSL certificate with Certbot on $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$LIGHTSAIL_PORT"
echo "  Domain: $CERTBOT_DOMAIN"
echo "  Email: $CERTBOT_EMAIL"

# SSH into instance and setup SSL certificate
ssh -i "$SSH_KEY_PATH" -p "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new "$LIGHTSAIL_USER@$LIGHTSAIL_HOST" << EOF
set -e

echo "=== Checking existing certificates ==="
if sudo certbot certificates 2>/dev/null | grep -q "$CERTBOT_DOMAIN"; then
    echo "Certificate already exists for $CERTBOT_DOMAIN"
    sudo certbot certificates
    echo "✓ Using existing certificate"
else
    echo "=== Obtaining new certificate ==="
    sudo certbot --nginx -d $CERTBOT_DOMAIN \\
        --non-interactive \\
        --agree-tos \\
        --email $CERTBOT_EMAIL \\
        --redirect || {
        echo "Error: Failed to obtain certificate"
        exit 1
    }
    
    echo "✓ Certificate obtained successfully"
fi

echo "=== Verifying auto-renewal timer ==="
sudo systemctl status certbot.timer --no-pager -l || sudo systemctl enable certbot.timer

echo "=== Certificate details ==="
sudo certbot certificates

echo "✓ SSL certificate setup completed successfully"
EOF

if [ $? -eq 0 ]; then
    echo "✓ SSL certificate setup completed successfully"
    exit 0
else
    echo "Error: Failed to setup SSL certificate"
    exit 1
fi

