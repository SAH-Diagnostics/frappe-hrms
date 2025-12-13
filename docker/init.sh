#!/bin/bash

set -e

DB_HOST_VALUE="${DB_HOST:-${RDS_HOSTNAME:-}}"
DB_PORT_VALUE="${DB_PORT:-${RDS_PORT:-3306}}"
DB_USER_VALUE="${DB_USER:-${RDS_USERNAME:-root}}"
DB_PASSWORD_VALUE="${DB_PASSWORD:-${RDS_PASSWORD:-123}}"
DB_NAME_VALUE="${DB_NAME:-${RDS_DB_NAME:-}}"
ADMIN_PASSWORD_VALUE="${ADMIN_PASSWORD:-admin}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"

echo "=== Installing AWS CLI ==="
# Install aws-cli if not already installed
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    
    # Update package list and install dependencies (use sudo for apt-get)
    sudo apt-get update -qq
    sudo apt-get install -y -qq unzip curl
    
    # Detect architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
    else
        echo "Unsupported architecture: $ARCH. Using pip install."
        pip install awscli
    fi
    
    # Download and install AWS CLI
    if [ -n "$AWS_CLI_URL" ]; then
        echo "Downloading AWS CLI for $ARCH..."
        if curl -f "$AWS_CLI_URL" -o "/tmp/awscliv2.zip" 2>/dev/null; then
            echo "Extracting and installing AWS CLI..."
            unzip -q /tmp/awscliv2.zip -d /tmp
            sudo /tmp/aws/install
            rm -rf /tmp/aws /tmp/awscliv2.zip
        else
            echo "Failed to download AWS CLI. Using pip install as fallback..."
            pip install awscli
        fi
    fi
    
    # Verify installation
    if command -v aws &> /dev/null; then
        echo "✓ AWS CLI installed successfully: $(aws --version)"
    else
        echo "✗ AWS CLI installation failed. Trying pip install..."
        pip install awscli
        if command -v aws &> /dev/null; then
            echo "✓ AWS CLI installed via pip: $(aws --version)"
        else
            echo "✗ Warning: AWS CLI installation failed. Backup scripts may not work."
        fi
    fi
else
    echo "✓ AWS CLI already installed: $(aws --version)"
fi

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

# For external RDS databases, try new-site first, fallback to manual creation if CREATE USER fails
if [ -n "$DB_HOST_VALUE" ] && [ -n "$DB_NAME_VALUE" ]; then
    echo "Creating site with RDS database..."
    
    # Try bench new-site first (might work if RDS allows it for master user)
    if bench new-site "$SITE_NAME" \
        --force \
        --db-host "$DB_HOST_VALUE" \
        --db-port "$DB_PORT_VALUE" \
        --db-user "$DB_USER_VALUE" \
        --db-password "$DB_PASSWORD_VALUE" \
        --db-name "$DB_NAME_VALUE" \
        --db-type "mariadb" \
        --db-root-password "$DB_PASSWORD_VALUE" \
        --db-root-username "$DB_USER_VALUE" \
        --admin-password "$ADMIN_PASSWORD_VALUE" \
        --verbose \
        --no-mariadb-socket 2>&1; then
        echo "Site created successfully using bench new-site"
    else
        echo "bench new-site failed (likely CREATE USER restriction), creating site manually..."
        
        # Create site directory structure
        mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME/logs"
        mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME/private"
        mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME/public"
        
        # Ensure target database exists (idempotent; requires privileges on RDS user)
        mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
            -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME_VALUE\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || true

        # Create site_config.json with RDS credentials
        cat > "/home/frappe/frappe-bench/sites/$SITE_NAME/site_config.json" << EOF
{
 "db_name": "$DB_NAME_VALUE",
 "db_password": "$DB_PASSWORD_VALUE",
 "db_port": $DB_PORT_VALUE,
 "db_host": "$DB_HOST_VALUE",
 "db_type": "mariadb",
 "db_user": "$DB_USER_VALUE",
 "developer_mode": 1,
 "webserver_port": "443"
}
EOF
        
        # Set global config
        bench set-config --global db_host "$DB_HOST_VALUE" 2>/dev/null || true
        bench set-config --global db_port "$DB_PORT_VALUE" 2>/dev/null || true
        
        # Initialize database schema using install-app frappe
        echo "Initializing database schema..."
        bench --site "$SITE_NAME" install-app frappe --force || {
            echo "Warning: install-app frappe failed, trying migrate..."
            bench --site "$SITE_NAME" migrate || true
        }
    fi
else
    # For local MariaDB, use standard new-site command
    bench new-site "$SITE_NAME" \
        --force \
        ${DB_NAME_VALUE:+--db-name "$DB_NAME_VALUE"} \
        ${DB_HOST_VALUE:+--db-host "$DB_HOST_VALUE"} \
        ${DB_PORT_VALUE:+--db-port "$DB_PORT_VALUE"} \
        --mariadb-root-password "$DB_PASSWORD_VALUE" \
        --mariadb-root-username "$DB_USER_VALUE" \
        --admin-password "$ADMIN_PASSWORD_VALUE" \
        --no-mariadb-socket
fi

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

# Force webserver_port to 443 so generated links do not append :8000
echo "=== Setting webserver_port to 443 ==="
bench set-config --global webserver_port 443 || true
bench --site "$SITE_NAME" set-config webserver_port 443

echo "=== Installing HRMS app ==="
bench --site "$SITE_NAME" install-app hrms
bench --site "$SITE_NAME" set-config developer_mode 1
bench --site "$SITE_NAME" enable-scheduler

bench --site "$SITE_NAME" clear-cache || true
bench use "$SITE_NAME" || true

echo "=== Creating S3 backup scripts ==="
# Create push-to-bucket.sh script
cat > /home/frappe/push-to-bucket.sh << 'PUSH_SCRIPT_EOF'
#!/bin/bash
set -e

# Load environment variables from file if available
if [ -f /home/frappe/s3-backup-env.sh ]; then
    source /home/frappe/s3-backup-env.sh
fi

# Load environment variables (with defaults)
SITE_NAME="${SITE_NAME:-dev-erp.sahdiagnostics.com}"
BUCKET_NAME="${BUCKET_NAME:-}"
BUCKET_ACCESS_KEY_ID="${BUCKET_ACCESS_KEY_ID:-}"
BUCKET_SECRET_ACCESS_KEY="${BUCKET_SECRET_ACCESS_KEY:-}"
BUCKET_REGION="${BUCKET_REGION:-eu-west-2}"
BUCKET_ENDPOINT="${BUCKET_ENDPOINT:-}"

if [ -z "$BUCKET_NAME" ] || [ -z "$BUCKET_ACCESS_KEY_ID" ] || [ -z "$BUCKET_SECRET_ACCESS_KEY" ]; then
    echo "Error: S3 bucket configuration is missing. Required: BUCKET_NAME, BUCKET_ACCESS_KEY_ID, BUCKET_SECRET_ACCESS_KEY"
    exit 1
fi

# Configure AWS CLI
export AWS_ACCESS_KEY_ID="$BUCKET_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$BUCKET_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$BUCKET_REGION"

# Base paths
SITE_DIR="/home/frappe/frappe-bench/sites/$SITE_NAME"
PRIVATE_DIR="$SITE_DIR/private"
PUBLIC_DIR="$SITE_DIR/public"
LOGS_DIR="$SITE_DIR/logs"

echo "=== Starting backup to S3 at $(date) ==="
echo "Site: $SITE_NAME"
echo "Bucket: $BUCKET_NAME"

# Sync private directory
if [ -d "$PRIVATE_DIR" ]; then
    echo "Backing up private directory..."
    if [ -n "$BUCKET_ENDPOINT" ]; then
        aws s3 sync "$PRIVATE_DIR" "s3://$BUCKET_NAME/private" --endpoint-url="$BUCKET_ENDPOINT" --no-progress || echo "Warning: Failed to sync private directory"
    else
        aws s3 sync "$PRIVATE_DIR" "s3://$BUCKET_NAME/private" --no-progress || echo "Warning: Failed to sync private directory"
    fi
else
    echo "Warning: Private directory not found: $PRIVATE_DIR"
fi

# Sync public directory
if [ -d "$PUBLIC_DIR" ]; then
    echo "Backing up public directory..."
    if [ -n "$BUCKET_ENDPOINT" ]; then
        aws s3 sync "$PUBLIC_DIR" "s3://$BUCKET_NAME/public" --endpoint-url="$BUCKET_ENDPOINT" --no-progress || echo "Warning: Failed to sync public directory"
    else
        aws s3 sync "$PUBLIC_DIR" "s3://$BUCKET_NAME/public" --no-progress || echo "Warning: Failed to sync public directory"
    fi
else
    echo "Warning: Public directory not found: $PUBLIC_DIR"
fi

# Sync logs directory
if [ -d "$LOGS_DIR" ]; then
    echo "Backing up logs directory..."
    if [ -n "$BUCKET_ENDPOINT" ]; then
        aws s3 sync "$LOGS_DIR" "s3://$BUCKET_NAME/logs" --endpoint-url="$BUCKET_ENDPOINT" --no-progress || echo "Warning: Failed to sync logs directory"
    else
        aws s3 sync "$LOGS_DIR" "s3://$BUCKET_NAME/logs" --no-progress || echo "Warning: Failed to sync logs directory"
    fi
else
    echo "Warning: Logs directory not found: $LOGS_DIR"
fi

echo "=== Backup completed at $(date) ==="
PUSH_SCRIPT_EOF

chmod +x /home/frappe/push-to-bucket.sh
chown frappe:frappe /home/frappe/push-to-bucket.sh

# Create fetch-from-bucket.sh script
cat > /home/frappe/fetch-from-bucket.sh << 'FETCH_SCRIPT_EOF'
#!/bin/bash
set -e

# Load environment variables from file if available
if [ -f /home/frappe/s3-backup-env.sh ]; then
    source /home/frappe/s3-backup-env.sh
fi

# Load environment variables (with defaults)
SITE_NAME="${SITE_NAME:-dev-erp.sahdiagnostics.com}"
BUCKET_NAME="${BUCKET_NAME:-}"
BUCKET_ACCESS_KEY_ID="${BUCKET_ACCESS_KEY_ID:-}"
BUCKET_SECRET_ACCESS_KEY="${BUCKET_SECRET_ACCESS_KEY:-}"
BUCKET_REGION="${BUCKET_REGION:-eu-west-2}"
BUCKET_ENDPOINT="${BUCKET_ENDPOINT:-}"

if [ -z "$BUCKET_NAME" ] || [ -z "$BUCKET_ACCESS_KEY_ID" ] || [ -z "$BUCKET_SECRET_ACCESS_KEY" ]; then
    echo "Warning: S3 bucket configuration is missing. Skipping fetch from bucket."
    exit 0
fi

# Configure AWS CLI
export AWS_ACCESS_KEY_ID="$BUCKET_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$BUCKET_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$BUCKET_REGION"

# Base paths
SITE_DIR="/home/frappe/frappe-bench/sites/$SITE_NAME"
PRIVATE_DIR="$SITE_DIR/private"
PUBLIC_DIR="$SITE_DIR/public"
LOGS_DIR="$SITE_DIR/logs"

echo "=== Fetching data from S3 at $(date) ==="
echo "Site: $SITE_NAME"
echo "Bucket: $BUCKET_NAME"

# Ensure directories exist
mkdir -p "$PRIVATE_DIR" "$PUBLIC_DIR" "$LOGS_DIR"
chown -R frappe:frappe "$SITE_DIR" 2>/dev/null || true

# Check if bucket has data and fetch
check_and_sync() {
    local local_dir="$1"
    local s3_path="$2"
    local dir_name="$3"
    
    echo "Checking $dir_name directory in bucket..."
    if [ -n "$BUCKET_ENDPOINT" ]; then
        if aws s3 ls "s3://$BUCKET_NAME/$s3_path" --endpoint-url="$BUCKET_ENDPOINT" &>/dev/null; then
            echo "Found $dir_name data in bucket, syncing..."
            aws s3 sync "s3://$BUCKET_NAME/$s3_path" "$local_dir" --endpoint-url="$BUCKET_ENDPOINT" --no-progress || echo "Warning: Failed to sync $dir_name directory"
        else
            echo "No $dir_name data found in bucket, skipping..."
        fi
    else
        if aws s3 ls "s3://$BUCKET_NAME/$s3_path" &>/dev/null; then
            echo "Found $dir_name data in bucket, syncing..."
            aws s3 sync "s3://$BUCKET_NAME/$s3_path" "$local_dir" --no-progress || echo "Warning: Failed to sync $dir_name directory"
        else
            echo "No $dir_name data found in bucket, skipping..."
        fi
    fi
    
    # Fix permissions
    chown -R frappe:frappe "$local_dir" 2>/dev/null || true
}

# Fetch each directory
check_and_sync "$PRIVATE_DIR" "private" "private"
check_and_sync "$PUBLIC_DIR" "public" "public"
check_and_sync "$LOGS_DIR" "logs" "logs"

echo "=== Fetch from bucket completed at $(date) ==="
FETCH_SCRIPT_EOF

chmod +x /home/frappe/fetch-from-bucket.sh
chown frappe:frappe /home/frappe/fetch-from-bucket.sh

echo "=== Creating S3 backup environment file ==="
# Export environment variables to a file that can be sourced by scripts and cron
cat > /home/frappe/s3-backup-env.sh << EOF
export SITE_NAME="${SITE_NAME:-dev-erp.sahdiagnostics.com}"
export BUCKET_NAME="${BUCKET_NAME:-}"
export BUCKET_ACCESS_KEY_ID="${BUCKET_ACCESS_KEY_ID:-}"
export BUCKET_SECRET_ACCESS_KEY="${BUCKET_SECRET_ACCESS_KEY:-}"
export BUCKET_REGION="${BUCKET_REGION:-eu-west-2}"
export BUCKET_ENDPOINT="${BUCKET_ENDPOINT:-}"
EOF
chmod 600 /home/frappe/s3-backup-env.sh
chown frappe:frappe /home/frappe/s3-backup-env.sh

echo "=== Setting up cron job for S3 backup ==="
# Set up cron job if FILES_BACK_UP_HOURS is set
FILES_BACK_UP_HOURS="${FILES_BACK_UP_HOURS:-}"
if [ -n "$FILES_BACK_UP_HOURS" ] && [ "$FILES_BACK_UP_HOURS" -gt 0 ] 2>/dev/null; then
    echo "Setting up cron job to run backup every $FILES_BACK_UP_HOURS hours"
    
    # Create a wrapper script that loads environment variables
    cat > /home/frappe/run-backup.sh << 'CRON_WRAPPER_EOF'
#!/bin/bash
# Source environment variables
if [ -f /home/frappe/s3-backup-env.sh ]; then
    source /home/frappe/s3-backup-env.sh
fi

# Run the backup script
/home/frappe/push-to-bucket.sh >> /home/frappe/backup.log 2>&1
CRON_WRAPPER_EOF

    chmod +x /home/frappe/run-backup.sh
    chown frappe:frappe /home/frappe/run-backup.sh
    
    # Start cron daemon if not running
    if ! pgrep -x cron > /dev/null; then
        echo "Starting cron daemon..."
        cron
    fi
    
    # Add cron job (runs every FILES_BACK_UP_HOURS hours)
    CRON_SCHEDULE="0 */${FILES_BACK_UP_HOURS} * * *"
    (crontab -l 2>/dev/null | grep -v "run-backup.sh"; echo "${CRON_SCHEDULE} /home/frappe/run-backup.sh") | crontab -
    echo "Cron job configured to run every $FILES_BACK_UP_HOURS hours"
else
    echo "FILES_BACK_UP_HOURS not set or invalid, skipping cron job setup"
fi

echo "=== Fetching data from S3 bucket (if available) ==="
# Run fetch-from-bucket.sh to restore any existing data
/home/frappe/fetch-from-bucket.sh || echo "Warning: Failed to fetch data from bucket (this is OK if bucket is empty)"

echo "=== Starting bench ==="
bench start