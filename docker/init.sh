#!/bin/bash

set -e  # Exit on error

# Determine database connection details
# Prefer DB_* variables, fall back to RDS_* for compatibility
DB_HOST_VALUE="${DB_HOST:-${RDS_HOSTNAME:-}}"
DB_PORT_VALUE="${DB_PORT:-${RDS_PORT:-3306}}"
DB_USER_VALUE="${DB_USER:-${RDS_USERNAME:-root}}"
DB_PASSWORD_VALUE="${DB_PASSWORD:-${RDS_PASSWORD:-123}}"
ADMIN_PASSWORD_VALUE="${ADMIN_PASSWORD:-admin}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"

echo "=== Using site name: $SITE_NAME ==="

# Check if bench already exists
if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "=== Bench already exists ==="
    cd frappe-bench
    
    # Update database host if environment variable is set (for switching databases)
    if [ ! -z "$DB_HOST_VALUE" ]; then
        echo "Updating database host to: $DB_HOST_VALUE:$DB_PORT_VALUE"
        bench set-mariadb-host "$DB_HOST_VALUE"
        bench set-mariadb-port "$DB_PORT_VALUE"
    else
        echo "Using existing database configuration"
        # Ensure it's set to local mariadb if not already configured
        CURRENT_HOST=$(bench get-config db_host 2>/dev/null || echo "")
        if [ -z "$CURRENT_HOST" ] || [ "$CURRENT_HOST" = "localhost" ]; then
            echo "Setting database host to local mariadb container"
            bench set-mariadb-host mariadb
            bench set-mariadb-port 3306
        fi
    fi
    
    # Check if site exists before starting
    if bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
        echo "✓ Site $SITE_NAME exists, starting bench..."
        bench start
    else
        echo "⚠️  Site $SITE_NAME does not exist in database"
        echo "   Bench exists but site is missing. Please create the site manually or"
        echo "   remove the bench directory to reinitialize."
        exit 1
    fi
    exit 0
fi

# Fresh installation path
echo "=== Creating new bench ==="

export PATH="${NVM_DIR}/versions/node/v${NODE_VERSION_DEVELOP}/bin/:${PATH}"

bench init --skip-redis-config-generation frappe-bench

cd frappe-bench

# Configure database connection
if [ ! -z "$DB_HOST_VALUE" ]; then
    echo "Connecting to external database: $DB_HOST_VALUE:$DB_PORT_VALUE"
    bench set-mariadb-host "$DB_HOST_VALUE"
    bench set-mariadb-port "$DB_PORT_VALUE"
else
    echo "Using local MariaDB container"
    bench set-mariadb-host mariadb
    bench set-mariadb-port 3306
fi

# Configure Redis
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

# Remove redis, watch from Procfile
sed -i '/redis/d' ./Procfile 2>/dev/null || true
sed -i '/watch/d' ./Procfile 2>/dev/null || true

# Get apps
echo "=== Getting apps ==="
bench get-app erpnext
bench get-app hrms

# Check if site already exists in database before creating
echo "=== Checking if site exists ==="
if bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
    echo "✓ Site $SITE_NAME already exists in database"
    
    if [ "$EXISTING_SITE" = "true" ]; then
        echo "  EXISTING_SITE=true: Using existing site data"
    else
        echo "  ⚠️  Site exists but EXISTING_SITE not set to 'true'"
        echo "  This may indicate the database already has data."
        echo "  Set EXISTING_SITE=true to use existing site, or use a different site name."
        exit 1
    fi
else
    echo "Site $SITE_NAME does not exist, creating new site..."
    
    # Verify database connectivity before creating site (optional check)
    if [ ! -z "$DB_HOST_VALUE" ]; then
        echo "Verifying database connectivity..."
        # Test external database connection if mysql client is available
        if command -v mysql >/dev/null 2>&1; then
            if ! mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" -e "SELECT 1;" >/dev/null 2>&1; then
                echo "✗ Error: Cannot connect to database at $DB_HOST_VALUE:$DB_PORT_VALUE"
                echo "  Please verify database credentials and network connectivity"
                exit 1
            fi
            echo "✓ Database connection verified"
        else
            echo "  (mysql client not available, connection will be verified during site creation)"
        fi
    fi
    
    bench new-site "$SITE_NAME" \
    --force \
    --mariadb-root-password "$DB_PASSWORD_VALUE" \
    --mariadb-root-username "$DB_USER_VALUE" \
    --admin-password "$ADMIN_PASSWORD_VALUE" \
    --no-mariadb-socket
    
    echo "=== Installing HRMS app ==="
    bench --site "$SITE_NAME" install-app hrms
    bench --site "$SITE_NAME" set-config developer_mode 1
    bench --site "$SITE_NAME" enable-scheduler
fi

# Final configuration
bench --site "$SITE_NAME" clear-cache
bench use "$SITE_NAME"

echo "=== Starting bench ==="
bench start