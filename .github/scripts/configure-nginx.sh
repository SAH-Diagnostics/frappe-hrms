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

VHOST=/etc/nginx/sites-available/$SITE_NAME

# Keep the running vhost so a config nginx rejects is never left in place (VC-652).
echo "=== Keeping the previous config ==="
if sudo test -f "\$VHOST"; then
    sudo cp -p "\$VHOST" "\$VHOST.previous"
else
    sudo rm -f "\$VHOST.previous"
fi

echo "=== Moving config to sites-available ==="
sudo mv $TEMP_REMOTE_PATH "\$VHOST"

echo "=== Creating symlink ==="
sudo ln -sf "\$VHOST" /etc/nginx/sites-enabled/$SITE_NAME

echo "=== Removing default site ==="
sudo rm -f /etc/nginx/sites-enabled/default

echo "=== Testing nginx configuration ==="
if sudo nginx -t; then
    echo "✓ Nginx configuration is valid"
else
    echo "Error: Nginx configuration test failed; restoring the previous config"
    if sudo test -f "\$VHOST.previous"; then
        sudo mv -f "\$VHOST.previous" "\$VHOST"
    else
        sudo rm -f "\$VHOST" /etc/nginx/sites-enabled/$SITE_NAME
    fi
    exit 1
fi

echo "=== Reloading nginx ==="
sudo systemctl reload nginx || sudo systemctl restart nginx

echo "=== Verifying nginx status ==="
sudo systemctl status nginx --no-pager -l || true

# A green run must mean HTTPS is served: this is the check that would have caught the
# 2026-09-24 prod run, which left nginx valid but listening on 80 only.
echo "=== Verifying HTTPS and the HTTP redirect on this host ==="
https_code=\$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    --resolve "$CERTBOT_DOMAIN:443:127.0.0.1" "https://$CERTBOT_DOMAIN/login" || true)
http_code=\$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    --resolve "$CERTBOT_DOMAIN:80:127.0.0.1" "http://$CERTBOT_DOMAIN/login" || true)
echo "  https: \$https_code   http: \$http_code"
if [ "\$https_code" = "000" ] || [ -z "\$https_code" ]; then
    echo "Error: nothing answered HTTPS with a valid certificate for $CERTBOT_DOMAIN"
    exit 1
fi
if [ "\$http_code" != "301" ]; then
    echo "Error: HTTP did not redirect to HTTPS (got \$http_code)"
    exit 1
fi

echo "✓ Nginx configured successfully"
EOF

if [ $? -eq 0 ]; then
    echo "✓ Nginx configuration completed successfully"
    exit 0
else
    echo "Error: Failed to configure Nginx"
    exit 1
fi

