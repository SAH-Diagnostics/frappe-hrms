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
SITE_URL="${SITE_URL:-http://localhost:8000}"

if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "Bench already exists, skipping init"
    cd /home/frappe/frappe-bench
    
    # Update site configuration if environment variables are provided
    if [ -f "sites/${SITE_NAME}/site_config.json" ]; then
        if [ "$DB_HOST" != "mariadb" ]; then
            echo "Updating database configuration..."
            bench set-config db_host "$DB_HOST" --site "$SITE_NAME"
            bench set-config db_port "$DB_PORT" --site "$SITE_NAME"
            bench set-config db_name "$DB_NAME" --site "$SITE_NAME"
        fi
        
        # Update host_name to ensure correct URL generation in emails
        echo "Updating site URL configuration..."
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
    # External database (RDS) - use master user directly, skip user creation
    echo "Creating site with external database: $DB_HOST:$DB_PORT"
    echo "Using master user directly: $DB_USER (no additional users will be created)"
    
    # Generate encryption key
    ENCRYPTION_KEY=$(openssl rand -base64 32)
    
    # Write common_site_config.json with root credentials
    # This tells Frappe to use these credentials for all DB operations
    cat > "sites/common_site_config.json" << EOF
{
    "db_host": "$DB_HOST",
    "db_port": $DB_PORT,
    "db_type": "mariadb",
    "root_login": "$DB_USER",
    "root_password": "$DB_PASSWORD"
}
EOF

    # Write site-specific config
    mkdir -p "sites/${SITE_NAME}"
    cat > "sites/${SITE_NAME}/site_config.json" << EOF
{
    "db_name": "$DB_NAME",
    "db_user": "$DB_USER",
    "db_password": "$DB_PASSWORD",
    "encryption_key": "$ENCRYPTION_KEY"
}
EOF

    echo "Site config created, initializing database schema..."
    
    # WORKAROUND: Patch Frappe to skip CREATE USER for RDS compatibility
    # RDS doesn't allow CREATE USER even for master users
    SETUP_DB_FILE="apps/frappe/frappe/database/mariadb/setup_db.py"
    if [ -f "$SETUP_DB_FILE" ]; then
        echo "Patching Frappe to skip user creation (RDS compatibility)..."
        # Comment out the create_user and grant_privileges calls
        sed -i 's/dbman.create_user/#dbman.create_user/g' "$SETUP_DB_FILE"
        sed -i 's/dbman.grant_all_privileges/#dbman.grant_all_privileges/g' "$SETUP_DB_FILE"
    fi
    
    # Now create the site - it will skip user creation due to the patch
    bench new-site "$SITE_NAME" \
        --force \
        --no-mariadb-socket \
        --db-host "$DB_HOST" \
        --db-port "$DB_PORT" \
        --db-name "$DB_NAME" \
        --db-user "$DB_USER" \
        --db-password "$DB_PASSWORD" \
        --db-root-username "$DB_USER" \
        --db-root-password "$DB_PASSWORD" \
        --admin-password admin \
        --install-app erpnext \
        --install-app hrms
else
    # Local MariaDB container (development)
    echo "Creating site with local MariaDB"
    bench set-mariadb-host mariadb
    bench new-site "$SITE_NAME" \
        --force \
        --mariadb-root-password "$DB_PASSWORD" \
        --admin-password admin
fi

# Install apps if not already installed during new-site (local dev only)
if [ "$DB_HOST" = "mariadb" ]; then
    bench --site "$SITE_NAME" install-app hrms || echo "HRMS already installed"
fi

# Configure site
bench --site "$SITE_NAME" set-config developer_mode 1
bench --site "$SITE_NAME" set-config host_name "$SITE_URL"
bench --site "$SITE_NAME" enable-scheduler
bench --site "$SITE_NAME" clear-cache
bench use "$SITE_NAME"

bench start