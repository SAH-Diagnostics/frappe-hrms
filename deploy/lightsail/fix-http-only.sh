#!/bin/bash

# Quick fix script to switch nginx to HTTP-only mode (no HTTPS redirect)
# Use this when HTTPS is not configured but nginx is redirecting HTTP to HTTPS

set -e

echo "=========================================="
echo "Switching Nginx to HTTP-only mode"
echo "=========================================="
echo ""

NGINX_CONFIG="/etc/nginx/sites-available/frappe-hrms"
NGINX_ENABLED="/etc/nginx/sites-enabled/frappe-hrms"

# Backup current config
if [ -f "$NGINX_CONFIG" ]; then
    echo "Creating backup of current nginx config..."
    sudo cp "$NGINX_CONFIG" "${NGINX_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "✓ Backup created"
fi

echo ""
echo "Creating HTTP-only nginx configuration..."

# Create HTTP-only nginx config
sudo tee "$NGINX_CONFIG" > /dev/null << 'NGINXCONF'
upstream frappe-server {
    server 127.0.0.1:8000 fail_timeout=0;
}

upstream socketio-server {
    server 127.0.0.1:9000 fail_timeout=0;
}

# HTTP server (no HTTPS redirect)
server {
    listen 80;
    listen [::]:80;
    server_name dev-hrms.sahdiagnostics.com www.dev-hrms.sahdiagnostics.com;

    client_max_body_size 50m;
    client_body_buffer_size 16k;
    client_body_timeout 60s;
    client_header_timeout 60s;
    
    # Allow certbot to validate domain (for future SSL setup)
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Main application
    location / {
        proxy_pass http://frappe-server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_buffering off;
        proxy_cache_bypass $http_upgrade;
    }

    # WebSocket for real-time updates
    location /socket.io {
        proxy_pass http://socketio-server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }

    # Static assets
    location /assets {
        proxy_pass http://frappe-server;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_cache_valid 200 60m;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # User uploaded files
    location /files {
        proxy_pass http://frappe-server;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_read_timeout 300;
        proxy_send_timeout 300;
    }
}
NGINXCONF

echo "✓ Nginx configuration created"

# Ensure site is enabled
sudo ln -sf "$NGINX_CONFIG" "$NGINX_ENABLED"
echo "✓ Nginx site enabled"

# Test nginx configuration
echo ""
echo "Testing nginx configuration..."
if sudo nginx -t; then
    echo "✓ Nginx configuration is valid"
else
    echo "✗ Nginx configuration test failed!"
    echo "Restoring backup..."
    if [ -f "${NGINX_CONFIG}.backup."* ]; then
        sudo cp "${NGINX_CONFIG}.backup."* "$NGINX_CONFIG" 2>/dev/null || true
    fi
    exit 1
fi

# Reload nginx
echo ""
echo "Reloading nginx..."
sudo systemctl reload nginx

echo ""
echo "=========================================="
echo "✓ Nginx switched to HTTP-only mode"
echo "=========================================="
echo ""
echo "Your site should now be accessible at:"
echo "  http://dev-hrms.sahdiagnostics.com"
echo ""
echo "To enable HTTPS later, run:"
echo "  cd /opt/frappe-hrms/deploy/lightsail"
echo "  sudo bash setup-ssl.sh"
echo ""

