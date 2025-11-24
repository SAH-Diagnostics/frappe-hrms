#!/bin/bash

set -euo pipefail

: "${NODE_VERSION_DEVELOP:=18}"
: "${NVM_DIR:=/home/frappe/.nvm}"

# Database configuration from environment variables (for production)
# Defaults to local MariaDB container for development
DB_HOST="${DB_HOST:-mariadb}"
DB_NAME="${DB_NAME:-frappe_db}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-123}"
DB_PORT="${DB_PORT:-3306}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"
SITE_URL="${SITE_URL:-http://hrms.localhost:8000}"

if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "Bench already exists, skipping init"
    cd /home/frappe/frappe-bench
    
    # Update site configuration if environment variables are provided
    if [ -f "sites/${SITE_NAME}/site_config.json" ]; then
        # Update database configuration if using external database
        if [ "$DB_HOST" != "mariadb" ]; then
            echo "Updating database configuration..."
            bench set-config db_host "$DB_HOST" --site "$SITE_NAME"
            bench set-config db_port "$DB_PORT" --site "$SITE_NAME"
            bench set-config db_name "$DB_NAME" --site "$SITE_NAME"
        fi
        
        # Always update the public site URL for email links and API redirects
        echo "Updating site URL to: $SITE_URL"
        bench set-config host_name "$SITE_URL" --site "$SITE_NAME"
    fi
    
    exec bench start
fi

echo "Creating new bench..."

export PATH="${NVM_DIR}/versions/node/v${NODE_VERSION_DEVELOP}/bin/:${PATH}"

bench init --skip-redis-config-generation frappe-bench

cd frappe-bench

# Configure Redis (required for all deployments)
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# Remove redis, watch from Procfile
sed -i '/redis/d' ./Procfile
sed -i '/watch/d' ./Procfile

bench get-app erpnext
bench get-app hrms

# Create site with appropriate database configuration
if [ "$DB_HOST" != "mariadb" ]; then
    # External database (production) - pass all config directly to new-site
    echo "Creating site with external database: $DB_HOST:$DB_PORT"
    bench new-site "$SITE_NAME" \
        --force \
        --db-host "$DB_HOST" \
        --db-port "$DB_PORT" \
        --db-name "$DB_NAME" \
        --mariadb-root-username "$DB_USER" \
        --mariadb-root-password "$DB_PASSWORD" \
        --admin-password admin \
        --no-mariadb-socket
else
    # Local MariaDB container (development)
    echo "Creating site with local MariaDB"
    bench set-mariadb-host mariadb
    bench new-site "$SITE_NAME" \
        --force \
        --mariadb-root-password "$DB_PASSWORD" \
        --admin-password admin \
        --no-mariadb-socket
fi

bench --site "$SITE_NAME" install-app hrms
bench --site "$SITE_NAME" set-config developer_mode 1
bench --site "$SITE_NAME" enable-scheduler

# Set the public site URL for email links and API redirects
echo "Setting site URL to: $SITE_URL"
bench --site "$SITE_NAME" set-config host_name "$SITE_URL"

bench --site "$SITE_NAME" clear-cache
bench use "$SITE_NAME"

bench start