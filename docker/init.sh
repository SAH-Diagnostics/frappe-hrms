#!/bin/bash

set -euo pipefail

: "${NODE_VERSION_DEVELOP:=18}"
: "${NVM_DIR:=/home/frappe/.nvm}"

# Database configuration from environment variables
# Defaults to local MariaDB container for development
DB_HOST="${DB_HOST:-mariadb}"
DB_NAME="${DB_NAME:-frappe_db}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-123}"
DB_PORT="${DB_PORT:-3306}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"
SITE_URL="${SITE_URL:-http://localhost:8000}"
# Default admin password to DB password if not set, assuming DB password is strong
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$DB_PASSWORD}"

# Validate critical secrets in non-local environments
if [ "$DB_HOST" != "mariadb" ]; then
    if [ "$DB_PASSWORD" == "123" ]; then
        echo "Error: DB_PASSWORD is using the default value '123' in a non-local environment."
        echo "Please set a secure DB_PASSWORD environment variable."
        exit 1
    fi
    # Removed warning for ADMIN_PASSWORD since user trusts DB_PASSWORD enough to use it as fallback
fi

# Safety toggles:
EXISTING_SITE_FLAG="${EXISTING_SITE:-false}"
ALLOW_NEW_SITE_ON_NONEMPTY_DB="${ALLOW_NEW_SITE_ON_NONEMPTY_DB:-0}"

# Helper: return 0 if the site directory/config already exists and the linked
# database appears to have a valid Frappe schema (for external DBs).
site_exists() {
    if [ ! -d "sites/${SITE_NAME}" ]; then
        return 1
    fi
    
    if [ ! -f "sites/${SITE_NAME}/site_config.json" ]; then
        return 1
    fi

    if [ "$DB_HOST" != "mariadb" ]; then
        if command -v mysql >/dev/null 2>&1; then
            local result
            # Added connect-timeout to prevent hanging
            result="$(mysql -N -s --connect-timeout=10 -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" \
                -e "SELECT 1 FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='tabDefaultValue' LIMIT 1;" 2>/dev/null || echo "ERR")"

            if [ "$result" != "1" ]; then
                echo "Site config exists for ${SITE_NAME} but database ${DB_NAME} appears uninitialised."
                return 1
            fi
        else
            echo "MySQL client is not available inside the container; treating external DB as uninitialised."
            return 1
        fi
    fi

    return 0
}

# Helper: for external DBs, return 0 if the database already exists
db_exists() {
    if [ "$DB_HOST" = "mariadb" ]; then
        return 1
    fi

    if command -v mysql >/dev/null 2>&1; then
        local result
        result="$(mysql -N -s --connect-timeout=10 -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" \
            -e "SELECT 1 FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='tabDefaultValue' LIMIT 1;" 2>/dev/null || echo "ERR")"

        if [ "$result" = "1" ]; then
            return 0
        fi
        return 1
    fi

    return 1
}

# Helper: for external DBs, return the number of tables in the target schema.
db_table_count() {
    if [ "$DB_HOST" = "mariadb" ]; then
        echo "0"
        return 0
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        echo "0"
        return 0
    fi

    local count
    count="$(mysql -N -s --connect-timeout=10 -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo "0")"
    echo "${count:-0}"
}

# Configure Lightsail / S3-compatible bucket for file storage if env vars are present
configure_bucket_storage() {
    if [ -n "${BUCKET_NAME:-}" ] && [ -n "${BUCKET_ACCESS_KEY_ID:-}" ] && [ -n "${BUCKET_SECRET_ACCESS_KEY:-}" ]; then
        echo "Configuring S3-compatible bucket for file storage..."
        bench --site "$SITE_NAME" set-config s3_file_system 1
        bench --site "$SITE_NAME" set-config s3_bucket "$BUCKET_NAME"

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
else
    echo "Creating new bench..."

    export PATH="${NVM_DIR}/versions/node/v${NODE_VERSION_DEVELOP}/bin/:${PATH}"

    bench init --skip-redis-config-generation frappe-bench

    cd frappe-bench

    # Configure Redis
    bench set-redis-cache-host redis://redis:6379
    bench set-redis-queue-host redis://redis:6379
    bench set-redis-socketio-host redis://redis:6379

    # Remove redis, watch from Procfile
    sed -i '/redis/d' ./Procfile
    sed -i '/watch/d' ./Procfile
fi

# Ensure apps are installed (even if bench already existed)
echo "Ensuring required apps are installed..."
export PATH="${NVM_DIR}/versions/node/v${NODE_VERSION_DEVELOP}/bin/:${PATH}"

if [ ! -d "apps/erpnext" ]; then
    echo "Installing erpnext app..."
    bench get-app erpnext
else
    echo "✓ erpnext app already exists"
fi

if [ ! -d "apps/hrms" ]; then
    echo "Installing hrms app..."
    bench get-app hrms
else
    echo "✓ hrms app already exists"
fi

if site_exists; then
    echo "Site ${SITE_NAME} already exists, applying configuration and migrations..."

    mkdir -p "sites/${SITE_NAME}/logs"
    mkdir -p "sites/${SITE_NAME}/public/files"
    mkdir -p "sites/${SITE_NAME}/private/files"

    if [ "$DB_HOST" != "mariadb" ]; then
        echo "Updating database configuration..."
        mkdir -p sites

        # Write common_site_config.json
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
else
    echo "No existing site ${SITE_NAME} found, creating site with appropriate database configuration"

    if [ -d "sites/${SITE_NAME}" ]; then
        rm -rf "sites/${SITE_NAME}"
    fi
    
    if [ -f "sites/sites.txt" ]; then
        grep -v "^${SITE_NAME}$" "sites/sites.txt" > "sites/sites.txt.tmp" 2>/dev/null || true
        if [ -f "sites/sites.txt.tmp" ]; then
            mv "sites/sites.txt.tmp" "sites/sites.txt"
        fi
    fi

    if [ "$DB_HOST" != "mariadb" ]; then
        mkdir -p sites
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
    fi

    if [ "$DB_HOST" != "mariadb" ]; then
        echo "Using external database: $DB_HOST:$DB_PORT"

        if db_exists; then
            echo "Database ${DB_NAME} already exists, skipping bench new-site."
            mkdir -p "sites/${SITE_NAME}"

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

            mkdir -p "sites/${SITE_NAME}/logs"
            mkdir -p "sites/${SITE_NAME}/public/files"
            mkdir -p "sites/${SITE_NAME}/private/files"

            echo "Running migrations against existing external database..."
            bench --site "$SITE_NAME" migrate
        else
            # Check table count safety
            table_count="$(db_table_count)"
            if [ "$table_count" -gt 0 ] && [ "$ALLOW_NEW_SITE_ON_NONEMPTY_DB" != "1" ]; then
                echo "ERROR: Refusing to run 'bench new-site' on external database ${DB_NAME} because it already has ${table_count} tables."
                exit 1
            fi

            echo "Target database ${DB_NAME} does not exist yet (or is empty), creating new site..."

            mkdir -p sites
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

            # Workaround for RDS privileges
            SETUP_DB_FILE="apps/frappe/frappe/database/mariadb/setup_db.py"
            if [ -f "$SETUP_DB_FILE" ]; then
                echo "Patching Frappe for RDS compatibility..."
                # Verify content before patching
                if grep -q "dbman.create_user" "$SETUP_DB_FILE"; then
                    sed -i 's/dbman.create_user/#dbman.create_user/g' "$SETUP_DB_FILE"
                    sed -i 's/dbman.grant_all_privileges/#dbman.grant_all_privileges/g' "$SETUP_DB_FILE"
                    sed -i 's/dbman.flush_privileges/#dbman.flush_privileges/g' "$SETUP_DB_FILE"
                else
                     echo "Warning: dbman.create_user not found in $SETUP_DB_FILE, skipping patch."
                fi
            else
                echo "Error: setup_db.py not found at $SETUP_DB_FILE!"
                ls -R apps/frappe/frappe/database/ || true
            fi

            if [ -d "sites/${SITE_NAME}" ]; then
                rm -rf "sites/${SITE_NAME}"
            fi
            if [ -f "sites/sites.txt" ]; then
                grep -v "^${SITE_NAME}$" "sites/sites.txt" > "sites/sites.txt.tmp" 2>/dev/null || true
                mv "sites/sites.txt.tmp" "sites/sites.txt" 2>/dev/null || true
            fi

            bench new-site "$SITE_NAME" \
                --force \
                --mariadb-user-host-login-scope='%' \
                --db-host "$DB_HOST" \
                --db-port "$DB_PORT" \
                --db-name "$DB_NAME" \
                --db-user "$DB_USER" \
                --db-password "$DB_PASSWORD" \
                --db-root-username "$DB_USER" \
                --db-root-password "$DB_PASSWORD" \
                --admin-password "$ADMIN_PASSWORD" \
                --install-app erpnext \
                --install-app hrms
        fi
    else
        echo "Creating site with local MariaDB"
        bench set-mariadb-host mariadb
        bench new-site "$SITE_NAME" \
            --mariadb-root-password "$DB_PASSWORD" \
            --admin-password "$ADMIN_PASSWORD"
    fi
fi

if [ "$DB_HOST" = "mariadb" ]; then
    bench --site "$SITE_NAME" install-app hrms || echo "HRMS already installed"
fi

bench --site "$SITE_NAME" set-config developer_mode 1
bench --site "$SITE_NAME" set-config host_name "$SITE_URL"

configure_bucket_storage

bench --site "$SITE_NAME" enable-scheduler
bench --site "$SITE_NAME" clear-cache
bench use "$SITE_NAME"

bench start
