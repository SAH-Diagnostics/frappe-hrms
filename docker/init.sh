#!/bin/bash

set -e  # Exit on error

# Fix permissions on mounted volumes at startup
echo "=== Fixing permissions ==="
# Ensure sites directory exists and has correct permissions
mkdir -p /home/frappe/frappe-bench/sites

# Try to fix ownership (may fail if running as non-root, that's okay)
if [ -w /home/frappe/frappe-bench/sites ]; then
    echo "✓ Sites directory is writable"
else
    echo "⚠️  Sites directory is not writable, attempting to fix permissions..."
    # Try with sudo if available, otherwise try without
    sudo chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null || \
    chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null || \
    echo "Note: Could not change ownership (may need to run container with proper user)"
fi

# Ensure write permissions
chmod -R u+w /home/frappe/frappe-bench/sites 2>/dev/null || \
sudo chmod -R u+w /home/frappe/frappe-bench/sites 2>/dev/null || true

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
    cd /home/frappe/frappe-bench
    
    # Fix permissions on bench directory
    echo "Fixing permissions on bench directory..."
    # Try multiple methods to fix permissions
    if sudo -n true 2>/dev/null; then
        sudo chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null || true
        sudo chmod -R u+w /home/frappe/frappe-bench/sites 2>/dev/null || true
    else
        chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null || true
        chmod -R u+w /home/frappe/frappe-bench/sites 2>/dev/null || true
    fi
    
    # Verify permissions on critical files
    if [ -f "/home/frappe/frappe-bench/sites/common_site_config.json" ]; then
        if [ ! -w "/home/frappe/frappe-bench/sites/common_site_config.json" ]; then
            echo "⚠️  common_site_config.json is not writable, fixing..."
            chmod u+w /home/frappe/frappe-bench/sites/common_site_config.json 2>/dev/null || \
            sudo chmod u+w /home/frappe/frappe-bench/sites/common_site_config.json 2>/dev/null || true
        fi
    fi
    
    # Ensure we're in the bench directory for all commands
    cd /home/frappe/frappe-bench
    pwd
    echo "Current directory: $(pwd)"
    
    # Update database configuration if environment variables are set
    if [ ! -z "$DB_HOST_VALUE" ]; then
        echo "Updating database host to: $DB_HOST_VALUE:$DB_PORT_VALUE"
        bench set-mariadb-host "$DB_HOST_VALUE" || bench set-config db_host "$DB_HOST_VALUE"
        bench set-config db_port "$DB_PORT_VALUE" 2>/dev/null || true
    else
        echo "Using existing database configuration"
        # Ensure it's set to local mariadb if not already configured
        CURRENT_HOST=$(bench get-config db_host 2>/dev/null || echo "")
        if [ -z "$CURRENT_HOST" ] || [ "$CURRENT_HOST" = "localhost" ]; then
            echo "Setting database host to local mariadb container"
            bench set-mariadb-host mariadb || bench set-config db_host mariadb
            bench set-config db_port 3306 2>/dev/null || true
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

cd /home/frappe/frappe-bench

# Ensure proper ownership and permissions
chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null || true
chmod -R u+w /home/frappe/frappe-bench/sites 2>/dev/null || true

# Ensure permissions are correct before running bench commands
chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null || true
chmod -R u+w /home/frappe/frappe-bench/sites 2>/dev/null || true

# Configure database connection
if [ ! -z "$DB_HOST_VALUE" ]; then
    echo "Connecting to external database: $DB_HOST_VALUE:$DB_PORT_VALUE"
    bench set-mariadb-host "$DB_HOST_VALUE" || bench set-config db_host "$DB_HOST_VALUE"
    bench set-config db_port "$DB_PORT_VALUE" 2>/dev/null || true
else
    echo "Using local MariaDB container"
    bench set-mariadb-host mariadb || bench set-config db_host mariadb
    bench set-config db_port 3306 2>/dev/null || true
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

# Remove site directory if it exists (from previous failed attempts or volume persistence)
# This MUST be done before attempting to create site, as bench checks directory first
echo "=== Checking for existing site directory ==="
if [ -d "/home/frappe/frappe-bench/sites/$SITE_NAME" ]; then
    echo "⚠️  Site directory exists, removing it to allow fresh site creation..."
    rm -rf "/home/frappe/frappe-bench/sites/$SITE_NAME"
    echo "✓ Site directory removed"
fi

# Check if site already exists in database (only if EXISTING_SITE is true)
if [ "$EXISTING_SITE" = "true" ]; then
    echo "=== EXISTING_SITE=true: Checking if site exists in database ==="
    # Create a minimal site directory structure to check database
    mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME"
    if bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
        echo "✓ Site $SITE_NAME exists in database, using existing site"
    else
        echo "⚠️  EXISTING_SITE=true but site does not exist in database"
        echo "  Creating new site instead..."
        rm -rf "/home/frappe/frappe-bench/sites/$SITE_NAME"
        EXISTING_SITE="false"
    fi
fi

# Create new site if needed
if [ "$EXISTING_SITE" != "true" ]; then
    echo "=== Creating new site: $SITE_NAME ==="
    
    # Ensure site directory doesn't exist (double-check)
    if [ -d "/home/frappe/frappe-bench/sites/$SITE_NAME" ]; then
        echo "⚠️  Removing stale site directory..."
        rm -rf "/home/frappe/frappe-bench/sites/$SITE_NAME"
        echo "✓ Site directory removed"
    fi
    
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
    
    # Create site with force flag to overwrite any remaining traces
    bench new-site "$SITE_NAME" \
    --force \
    --mariadb-root-password "$DB_PASSWORD_VALUE" \
    --mariadb-root-username "$DB_USER_VALUE" \
    --admin-password "$ADMIN_PASSWORD_VALUE" \
    --no-mariadb-socket || {
        echo "✗ Error: Failed to create site. Attempting to remove site directory and retry..."
        rm -rf "/home/frappe/frappe-bench/sites/$SITE_NAME"
        bench new-site "$SITE_NAME" \
        --force \
        --mariadb-root-password "$DB_PASSWORD_VALUE" \
        --mariadb-root-username "$DB_USER_VALUE" \
        --admin-password "$ADMIN_PASSWORD_VALUE" \
        --no-mariadb-socket
    }
    
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