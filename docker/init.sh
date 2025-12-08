#!/bin/bash

set -e

DB_HOST_VALUE="${DB_HOST:-${RDS_HOSTNAME:-}}"
DB_PORT_VALUE="${DB_PORT:-${RDS_PORT:-3306}}"
DB_USER_VALUE="${DB_USER:-${RDS_USERNAME:-root}}"
DB_PASSWORD_VALUE="${DB_PASSWORD:-${RDS_PASSWORD:-123}}"
DB_NAME_VALUE="${DB_NAME:-${RDS_DB_NAME:-}}"
ADMIN_PASSWORD_VALUE="${ADMIN_PASSWORD:-admin}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"

echo "=== Recreating bench and site (${SITE_NAME}) ==="

# Ensure node in PATH for bench
export PATH="${NVM_DIR}/versions/node/v${NODE_VERSION_DEVELOP}/bin/:${PATH}"

# Always start from a clean bench inside the container
BENCH_DIR="/home/frappe/frappe-bench"
cd /home/frappe
rm -rf "$BENCH_DIR" 2>/dev/null || true
bench init --skip-redis-config-generation frappe-bench
cd "$BENCH_DIR"

# Basic ownership to avoid permission surprises
chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null || true
chmod -R u+w /home/frappe/frappe-bench/sites 2>/dev/null || true

# Database configuration (write to common_site_config before site exists)
if [ -n "$DB_HOST_VALUE" ]; then
    echo "Configuring external database: $DB_HOST_VALUE:$DB_PORT_VALUE"
    bench set-config --global db_host "$DB_HOST_VALUE" 2>/dev/null || true
    bench set-config --global db_port "$DB_PORT_VALUE" 2>/dev/null || true
else
    echo "Configuring local MariaDB container"
    bench set-config --global db_host mariadb 2>/dev/null || true
    bench set-config --global db_port 3306 2>/dev/null || true
fi

# Redis endpoints (global scope)
bench set-config --global redis_cache redis://redis:6379 || true
bench set-config --global redis_queue redis://redis:6379 || true
bench set-config --global redis_socketio redis://redis:6379 || true

# Remove unused processes
sed -i '/redis/d' ./Procfile 2>/dev/null || true
sed -i '/watch/d' ./Procfile 2>/dev/null || true

echo "=== Getting apps ==="
bench get-app erpnext || echo "Warning: Failed to get erpnext app (may already exist)"
bench get-app hrms || echo "Warning: Failed to get hrms app (may already exist)"

echo "=== Recreating site: $SITE_NAME ==="
# Drop existing site if present, then remove its files
if bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
    bench drop-site "$SITE_NAME" --force --no-backup || true
fi
rm -rf "/home/frappe/frappe-bench/sites/$SITE_NAME" 2>/dev/null || true

bench new-site "$SITE_NAME" \
    --force \
    ${DB_NAME_VALUE:+--db-name "$DB_NAME_VALUE"} \
    ${DB_HOST_VALUE:+--db-host "$DB_HOST_VALUE"} \
    ${DB_PORT_VALUE:+--db-port "$DB_PORT_VALUE"} \
    --mariadb-root-password "$DB_PASSWORD_VALUE" \
    --mariadb-root-username "$DB_USER_VALUE" \
    --admin-password "$ADMIN_PASSWORD_VALUE" \
    --no-mariadb-socket

# Ensure the site knows its public URL so generated links use the correct host
if [ -n "$SITE_URL" ]; then
    HOST_URL="${SITE_URL%/}"
    # Default to https if no scheme provided
    if [[ "$HOST_URL" != http*://* ]]; then
        HOST_URL="https://${HOST_URL}"
    fi
    echo "=== Setting host_name to ${HOST_URL} ==="
    bench --site "$SITE_NAME" set-config host_name "$HOST_URL"
fi

echo "=== Installing HRMS app ==="
bench --site "$SITE_NAME" install-app hrms
bench --site "$SITE_NAME" set-config developer_mode 1
bench --site "$SITE_NAME" enable-scheduler

bench --site "$SITE_NAME" clear-cache || true
bench use "$SITE_NAME" || true

echo "=== Starting bench ==="
bench start