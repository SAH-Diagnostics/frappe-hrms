#!/bin/bash
set -euo pipefail

# render-nginx-conf.sh
# Purpose: Write the nginx vhost for the ERP site: HTTP redirects to HTTPS, and HTTPS
#          proxies to Frappe with the VC-652 security headers.
# Arguments:
#   $1 - CERTBOT_DOMAIN (also the certbot cert name, see setup-certbot.sh)
#   $2 - output file
#
# This is the only source of the vhost. The configure-nginx-* workflows used to carry an
# HTTP-only copy each; a run replaced the 443 block certbot had added, and setup-certbot.sh
# skips a host that already has a certificate, so HTTPS stayed down (prod, 2026-09-24).
# The certificate must exist before this file is installed: the workflows run
# setup-certbot.sh first, and configure-nginx.sh restores the previous vhost if
# `nginx -t` rejects this one.

if [ $# -ne 2 ]; then
    echo "Usage: $0 <CERTBOT_DOMAIN> <output_file>" >&2
    exit 1
fi

DOMAIN="$1"
OUTPUT="$2"

# The domain is written into nginx directives; accept a hostname and nothing else.
if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
    echo "Error: CERTBOT_DOMAIN is not a hostname" >&2
    exit 1
fi

# A location with its own add_header drops every add_header inherited from the server
# block, so /assets repeats these.
SECURITY_HEADERS='add_header Strict-Transport-Security "max-age=31536000" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;'

cat > "$OUTPUT" << EOF
upstream frappe {
    server localhost:8000;
}

server {
    listen 80;
    server_name $DOMAIN;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 50M;

    $SECURITY_HEADERS

    location / {
        proxy_pass http://frappe;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }

    location /assets {
        proxy_pass http://frappe;
        expires 7d;
        add_header Cache-Control "public, immutable";
        $SECURITY_HEADERS
    }
}
EOF

echo "✓ Nginx configuration generated"
