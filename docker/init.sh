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

# Helper: return 0 if the site directory/config already exists
site_exists() {
    [ -f "sites/${SITE_NAME}/site_config.json" ]
}

# Helper: for external DBs, return 0 if the database already exists
db_exists() {
    # Only meaningful when using an external MariaDB-compatible instance
    if [ "$DB_HOST" = "mariadb" ]; then
        return 1
    fi

    if command -v mysql >/dev/null 2>&1; then
        mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" \
            -e "USE \`$DB_NAME\`;" >/dev/null 2>&1
        return $?
    fi

    # If mysql client is not available, fall back to site_exists check only
    return 1
}

# Configure Lightsail / S3-compatible bucket for file storage if env vars are present
configure_bucket_storage() {
    if [ -n "${BUCKET_NAME:-}" ] && [ -n "${BUCKET_ACCESS_KEY_ID:-}" ] && [ -n "${BUCKET_SECRET_ACCESS_KEY:-}" ]; then
        echo "Configuring S3-compatible bucket for file storage..."
        bench --site "$SITE_NAME" set-config s3_file_system 1
        bench --site "$SITE_NAME" set-config s3_bucket "$BUCKET_NAME"

        # Region and endpoint are optional but recommended
        if [ -n "${BUCKET_REGION:-}" ]; then
            bench --site "$SITE_NAME" set-config s3_region "$BUCKET_REGION"
        fi
        if [ -n "${BUCKET_ENDPOINT:-}" ]; then
            bench --site "$SITE_NAME" set-config s3_endpoint_url "https://${BUCKET_ENDPOINT}"
        fi

        bench --site "$SITE_NAME" set-config s3_access_key_id "$BUCKET_ACCESS_KEY_ID"
        bench --site "$SITE_NAME" set-config s3_secret_access_key "$BUCKET_SECRET_ACCESS_KEY"
    fi
}

if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "Bench already exists, reusing existing setup"
    cd /home/frappe/frappe-bench

    if site_exists; then
        echo "Site ${SITE_NAME} already exists, applying configuration and migrations..."

        # Ensure required directories exist (logs and file storage)
        mkdir -p "sites/${SITE_NAME}/logs"
        mkdir -p "sites/${SITE_NAME}/public/files"
        mkdir -p "sites/${SITE_NAME}/private/files"

        if [ "$DB_HOST" != "mariadb" ]; then
            echo "Updating database configuration..."

            # ALWAYS update common_site_config.json to ensure correct external DB settings
            cat > "sites/common_site_config.json" << EOF
{
    "db_host": "$DB_HOST",
    "db_port": $DB_PORT,
    "db_type": "mariadb",
    "root_login": "$DB_USER",
    "root_password": "$DB_PASSWORD",
    "redis_cache": "redis://redis:6379",
    "redis_queue": "redis://redis:6379",
    "redis_socketio": "redis://redis:6379"
}
EOF

            bench --site "$SITE_NAME" set-config db_host "$DB_HOST"
            bench --site "$SITE_NAME" set-config db_port "$DB_PORT"
            bench --site "$SITE_NAME" set-config db_name "$DB_NAME"
        fi

        echo "Updating site URL configuration..."
        bench --site "$SITE_NAME" set-config host_name "$SITE_URL"

        echo "Running database migrations..."
        bench --site "$SITE_NAME" migrate

        # Ensure bucket configuration is applied even when bench/site already exist
        configure_bucket_storage

        bench --site "$SITE_NAME" enable-scheduler
        bench --site "$SITE_NAME" clear-cache

        bench use "$SITE_NAME"
        exec bench start
    fi

    echo "No existing site named ${SITE_NAME} found in this bench, continuing with init..."
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

if site_exists; then
    echo "Site ${SITE_NAME} already exists in freshly created bench."
    # Ensure required directories exist (logs and file storage)
    mkdir -p "sites/${SITE_NAME}/logs"
    mkdir -p "sites/${SITE_NAME}/public/files"
    mkdir -p "sites/${SITE_NAME}/private/files"
    echo "Running migrations instead of creating a new site..."
    bench --site "$SITE_NAME" migrate
else
    echo "No existing site ${SITE_NAME} found, creating site with appropriate database configuration"

    # Create site with appropriate database configuration
    if [ "$DB_HOST" != "mariadb" ]; then
        # External database (RDS) - use master user directly, skip user creation
        echo "Using external database: $DB_HOST:$DB_PORT"
        echo "Using master user directly: $DB_USER (no additional users will be created)"

        # If the target database already exists, avoid running bench new-site
        if db_exists; then
            echo "Database ${DB_NAME} already exists on ${DB_HOST}:${DB_PORT}, skipping bench new-site."
            # Ensure basic config files exist so Frappe can connect
            mkdir -p "sites/${SITE_NAME}"

            # ALWAYS update common_site_config.json when using external database
            # (don't just check if it exists, as it may have old localhost settings)
            cat > "sites/common_site_config.json" << EOF
{
    "db_host": "$DB_HOST",
    "db_port": $DB_PORT,
    "db_type": "mariadb",
    "root_login": "$DB_USER",
    "root_password": "$DB_PASSWORD",
    "redis_cache": "redis://redis:6379",
    "redis_queue": "redis://redis:6379",
    "redis_socketio": "redis://redis:6379"
}
EOF

            if [ ! -f "sites/${SITE_NAME}/site_config.json" ]; then
                ENCRYPTION_KEY=$(openssl rand -base64 32)
                cat > "sites/${SITE_NAME}/site_config.json" << EOF
{
    "db_name": "$DB_NAME",
    "db_user": "$DB_USER",
    "db_password": "$DB_PASSWORD",
    "encryption_key": "$ENCRYPTION_KEY"
}
EOF
            fi

            # Ensure required directories exist (logs and file storage)
            mkdir -p "sites/${SITE_NAME}/logs"
            mkdir -p "sites/${SITE_NAME}/public/files"
            mkdir -p "sites/${SITE_NAME}/private/files"

            echo "Running migrations against existing external database..."
            bench --site "$SITE_NAME" migrate
        else
            # Brand new external database: perform full site creation
            echo "Target database ${DB_NAME} does not exist yet, creating new site..."

            # Generate encryption key
            ENCRYPTION_KEY=$(openssl rand -base64 32)

            # Write common_site_config.json with root credentials and Redis config
            # This tells Frappe to use these credentials for all DB operations
            cat > "sites/common_site_config.json" << EOF
{
    "db_host": "$DB_HOST",
    "db_port": $DB_PORT,
    "db_type": "mariadb",
    "root_login": "$DB_USER",
    "root_password": "$DB_PASSWORD",
    "redis_cache": "redis://redis:6379",
    "redis_queue": "redis://redis:6379",
    "redis_socketio": "redis://redis:6379"
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

            # WORKAROUND: Patch Frappe to skip privileged operations for RDS compatibility
            # RDS doesn't allow CREATE USER, GRANT, or FLUSH PRIVILEGES for standard users
            SETUP_DB_FILE="apps/frappe/frappe/database/mariadb/setup_db.py"
            if [ -f "$SETUP_DB_FILE" ]; then
                echo "Patching Frappe for RDS compatibility (skipping user/privilege management)..."
                # Comment out all privileged database operations
                sed -i 's/dbman.create_user/#dbman.create_user/g' "$SETUP_DB_FILE"
                sed -i 's/dbman.grant_all_privileges/#dbman.grant_all_privileges/g' "$SETUP_DB_FILE"
                sed -i 's/dbman.flush_privileges/#dbman.flush_privileges/g' "$SETUP_DB_FILE"
            fi

            # Now create the site - it will skip user creation due to the patch
            bench new-site "$SITE_NAME" \
                --mariadb-user-host-login-scope='%' \
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
        fi
    else
        # Local MariaDB container (development)
        echo "Creating site with local MariaDB"
        bench set-mariadb-host mariadb
        bench new-site "$SITE_NAME" \
            --mariadb-root-password "$DB_PASSWORD" \
            --admin-password admin
    fi
fi

# Install apps if not already installed during new-site (local dev only)
if [ "$DB_HOST" = "mariadb" ]; then
    bench --site "$SITE_NAME" install-app hrms || echo "HRMS already installed"
fi

# Configure site
bench --site "$SITE_NAME" set-config developer_mode 1
bench --site "$SITE_NAME" set-config host_name "$SITE_URL"

configure_bucket_storage

bench --site "$SITE_NAME" enable-scheduler
bench --site "$SITE_NAME" clear-cache
bench use "$SITE_NAME"

bench start