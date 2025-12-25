#!/bin/bash
# Minimal init.sh that orchestrates all setup scripts
# All bench commands have been replaced with manual operations

set -e

# Determine script directory
INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$INIT_DIR/scripts"

# Ensure scripts directory exists
if [ ! -d "$SCRIPTS_DIR" ]; then
    echo "Error: scripts directory not found: $SCRIPTS_DIR"
    exit 1
fi

# Make all scripts executable
chmod +x "$SCRIPTS_DIR"/*.sh 2>/dev/null || true

echo "=========================================="
echo "Frappe HRMS Initialization"
echo "=========================================="

# Step 1: Upgrade Python (if upgrade script exists)
if [ -f "$INIT_DIR/upgrade-python.sh" ]; then
    echo ""
    bash "$INIT_DIR/upgrade-python.sh" || {
        echo "Warning: Python upgrade script failed, continuing with system Python"
    }
    # Ensure pyenv shims are in PATH for subsequent commands
    if [ -d "$HOME/.pyenv" ]; then
        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/shims:$PYENV_ROOT/bin:$PATH"
        eval "$(pyenv init -)" 2>/dev/null || true
    fi
fi

# Step 2: Install AWS CLI
if [ -f "$SCRIPTS_DIR/install-aws-cli.sh" ]; then
    echo ""
    bash "$SCRIPTS_DIR/install-aws-cli.sh"
else
    echo ""
    echo "=== Installing AWS CLI ==="
    if ! command -v aws &> /dev/null; then
        echo "Warning: install-aws-cli.sh not found and AWS CLI not installed"
    else
        echo "✓ AWS CLI already installed: $(aws --version)"
    fi
fi

# Step 3: Setup bench (directory structure, Frappe clone, venv)
echo ""
bash "$SCRIPTS_DIR/setup-bench.sh"

# Step 4: Configure database and Redis
echo ""
bash "$SCRIPTS_DIR/setup-database-config.sh"

# Step 5: Get and setup apps (erpnext, hrms)
echo ""
bash "$SCRIPTS_DIR/setup-apps.sh"

# Step 6: Setup site (create site, initialize database)
echo ""
bash "$SCRIPTS_DIR/setup-site.sh"

# Step 7: Install HRMS app
echo ""
echo "=== Installing HRMS app ==="
bash "$SCRIPTS_DIR/install-app-manual.sh" hrms || {
    echo "Warning: HRMS app installation failed or already installed"
}

# Step 8: Configure site (scheduler, developer mode, cache)
echo ""
bash "$SCRIPTS_DIR/configure-site.sh"

# Step 9: Install bucket helper scripts
echo ""
echo "=== Installing bucket helper scripts ==="
if [ -f "$INIT_DIR/bucket-env.sh" ]; then
    cp "$INIT_DIR/bucket-env.sh" "/home/frappe/bucket-env.sh"
    cp "$INIT_DIR/push-to-bucket.sh" "/home/frappe/push-to-bucket.sh"
    cp "$INIT_DIR/fetch-from-bucket.sh" "/home/frappe/fetch-from-bucket.sh"
    cp "$INIT_DIR/create-push-cron-job.sh" "/home/frappe/create-push-cron-job.sh"
    chmod +x /home/frappe/push-to-bucket.sh /home/frappe/fetch-from-bucket.sh /home/frappe/create-push-cron-job.sh 2>/dev/null || true
    chown frappe:frappe /home/frappe/push-to-bucket.sh /home/frappe/fetch-from-bucket.sh /home/frappe/create-push-cron-job.sh /home/frappe/bucket-env.sh 2>/dev/null || true
    echo "✓ Bucket helper scripts installed"
fi

# Step 10: Run initial fetch-from-bucket
echo ""
echo "=== Running initial fetch-from-bucket ==="
/home/frappe/fetch-from-bucket.sh || echo "Warning: initial fetch-from-bucket.sh failed (bucket may be empty or AWS not configured)"

# Step 11: Configure cron job for backups
echo ""
echo "=== Configuring cron job for periodic backups ==="
/home/frappe/create-push-cron-job.sh || echo "Warning: create-push-cron-job.sh failed; automatic backups may not run"

# Step 12: Start bench
echo ""
echo "=========================================="
echo "Starting bench processes..."
echo "=========================================="
bash "$SCRIPTS_DIR/start-bench.sh"

