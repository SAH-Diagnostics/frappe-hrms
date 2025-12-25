#!/bin/bash
# Setup database and Redis configuration in common_site_config.json

set -e

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
DB_HOST_VALUE="${DB_HOST:-${RDS_HOSTNAME:-}}"
DB_PORT_VALUE="${DB_PORT:-${RDS_PORT:-3306}}"
DB_USER_VALUE="${DB_USER:-${RDS_USERNAME:-root}}"

echo "=== Configuring database and Redis ==="

cd "$BENCH_DIR"

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/frappe-utils.sh" 2>/dev/null || true

# Create common_site_config.json if it doesn't exist
COMMON_CONFIG="$BENCH_DIR/sites/common_site_config.json"
if [ ! -f "$COMMON_CONFIG" ]; then
    echo "{}" > "$COMMON_CONFIG"
fi

# Configure database host and port
if [ -n "$DB_HOST_VALUE" ]; then
    echo "Configuring external database: $DB_HOST_VALUE:$DB_PORT_VALUE"
    "$BENCH_DIR/env/bin/python" -c "
import json
with open('$COMMON_CONFIG', 'r') as f:
    config = json.load(f)
config['db_host'] = '$DB_HOST_VALUE'
config['db_port'] = $DB_PORT_VALUE
with open('$COMMON_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
"
else
    echo "Configuring local MariaDB container"
    "$BENCH_DIR/env/bin/python" -c "
import json
with open('$COMMON_CONFIG', 'r') as f:
    config = json.load(f)
config['db_host'] = 'mariadb'
config['db_port'] = 3306
with open('$COMMON_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
"
fi

# Configure Redis endpoints
"$BENCH_DIR/env/bin/python" -c "
import json
with open('$COMMON_CONFIG', 'r') as f:
    config = json.load(f)
config['redis_cache'] = 'redis://redis:6379'
config['redis_queue'] = 'redis://redis:6379'
config['redis_socketio'] = 'redis://redis:6379'
config['webserver_port'] = 443
with open('$COMMON_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
"

# Remove unused processes from Procfile
if [ -f "$BENCH_DIR/Procfile" ]; then
    sed -i '/redis/d' "$BENCH_DIR/Procfile" 2>/dev/null || true
    sed -i '/watch/d' "$BENCH_DIR/Procfile" 2>/dev/null || true
fi

echo "✓ Database and Redis configuration complete"

