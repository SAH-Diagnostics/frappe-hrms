#!/bin/bash
set -e

# configure-nginx.sh
# Purpose: Configure Nginx on remote instance
# Arguments:
#   $1 - SITE_NAME
#   $2 - CERTBOT_DOMAIN
#   $3 - NGINX_CONFIG_FILE (local nginx config file path)
#   $4 - lightsail_user
#   $5 - lightsail_host
#   $6 - lightsail_port
#   $7 - ssh_key_path

# Display help if arguments are missing
if [ $# -lt 6 ]; then
    echo "Usage: $0 <SITE_NAME> <CERTBOT_DOMAIN> <NGINX_CONFIG_FILE> <lightsail_user> <lightsail_host> <lightsail_port> [ssh_key_path]"
    echo "Purpose: Configure Nginx on remote instance"
    exit 1
fi

SITE_NAME="$1"
CERTBOT_DOMAIN="$2"
NGINX_CONFIG_FILE="$3"
LIGHTSAIL_USER="$4"
LIGHTSAIL_HOST="$5"
LIGHTSAIL_PORT="$6"
SSH_KEY_PATH="${7:-~/.ssh/lightsail_key}"

# Expand ~ to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Configuring Nginx on $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$LIGHTSAIL_PORT"
echo "  Site Name: $SITE_NAME"
echo "  Domain: $CERTBOT_DOMAIN"

# Verify nginx config file exists
if [ ! -f "$NGINX_CONFIG_FILE" ]; then
    echo "Error: Nginx config file not found: $NGINX_CONFIG_FILE"
    exit 1
fi

# Copy nginx config to instance using copy-file-to-instance.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_REMOTE_PATH="/tmp/nginx.conf"

echo "=== Copying nginx config to instance ==="
"$SCRIPT_DIR/copy-file-to-instance.sh" \
    "$NGINX_CONFIG_FILE" \
    "$TEMP_REMOTE_PATH" \
    "$LIGHTSAIL_USER" \
    "$LIGHTSAIL_HOST" \
    "$LIGHTSAIL_PORT" \
    "$SSH_KEY_PATH"

# SSH into instance and configure nginx
ssh -i "$SSH_KEY_PATH" -p "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new "$LIGHTSAIL_USER@$LIGHTSAIL_HOST" << EOF
set -e

echo "=== Moving config to sites-available ==="
sudo mv $TEMP_REMOTE_PATH /etc/nginx/sites-available/$SITE_NAME

echo "=== Creating symlink ==="
sudo ln -sf /etc/nginx/sites-available/$SITE_NAME /etc/nginx/sites-enabled/$SITE_NAME

echo "=== Removing default site ==="
sudo rm -f /etc/nginx/sites-enabled/default

echo "=== Testing nginx configuration ==="
if sudo nginx -t; then
    echo "✓ Nginx configuration is valid"
else
    echo "Error: Nginx configuration test failed"
    exit 1
fi

echo "=== Reloading nginx ==="
sudo systemctl reload nginx || sudo systemctl restart nginx

echo "=== Verifying nginx status ==="
sudo systemctl status nginx --no-pager -l || true

echo "✓ Nginx configured successfully"
EOF

if [ $? -eq 0 ]; then
    echo "✓ Nginx configuration completed successfully"
    exit 0
else
    echo "Error: Failed to configure Nginx"
    exit 1
fi

