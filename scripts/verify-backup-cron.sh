#!/usr/bin/env bash
# Verification script to ensure backup cron job is created and runs successfully

set -euo pipefail

echo "=========================================="
echo "Backup Cron Job Verification Script"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PROJECT_PATH="/opt/frappe-hrms"
SCRIPT_PATH="${PROJECT_PATH}/scripts/sync-files-to-s3.sh"
ENV_FILE="${PROJECT_PATH}/deploy/dev/.env.remote"
LOG_FILE="/var/log/frappe-files-sync.log"

# Function to print status
print_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2"
    fi
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# 1. Check if script exists
echo "1. Checking backup script..."
if [ -f "$SCRIPT_PATH" ]; then
    print_status 0 "Script exists at: $SCRIPT_PATH"
    
    # Check if executable
    if [ -x "$SCRIPT_PATH" ]; then
        print_status 0 "Script is executable"
    else
        print_warning "Script is not executable, fixing..."
        sudo chmod +x "$SCRIPT_PATH"
        print_status 0 "Made script executable"
    fi
else
    print_status 1 "Script NOT found at: $SCRIPT_PATH"
    exit 1
fi

# 2. Check if env file exists
echo ""
echo "2. Checking environment file..."
if [ -f "$ENV_FILE" ]; then
    print_status 0 "Environment file exists"
    
    # Check required variables
    REQUIRED_VARS=("SITE_NAME" "BUCKET_NAME" "BUCKET_ACCESS_KEY_ID" "BUCKET_SECRET_ACCESS_KEY")
    MISSING_VARS=()
    
    for var in "${REQUIRED_VARS[@]}"; do
        if ! grep -q "^${var}=" "$ENV_FILE"; then
            MISSING_VARS+=("$var")
        fi
    done
    
    if [ ${#MISSING_VARS[@]} -eq 0 ]; then
        print_status 0 "All required environment variables are set"
    else
        print_status 1 "Missing required variables: ${MISSING_VARS[*]}"
    fi
else
    print_status 1 "Environment file NOT found at: $ENV_FILE"
    exit 1
fi

# 3. Check cron job
echo ""
echo "3. Checking cron job..."
CRON_EXISTS=$(sudo crontab -l 2>/dev/null | grep -c "sync-files-to-s3.sh" || echo "0")

if [ "$CRON_EXISTS" -gt 0 ]; then
    print_status 0 "Cron job exists"
    echo ""
    echo "Current cron job(s):"
    sudo crontab -l | grep "sync-files-to-s3.sh" | while read -r line; do
        echo "  $line"
    done
    
    # Check if there are multiple entries (should only be one)
    CRON_COUNT=$(sudo crontab -l 2>/dev/null | grep -c "sync-files-to-s3.sh" || echo "0")
    if [ "$CRON_COUNT" -gt 1 ]; then
        print_warning "Multiple cron entries found ($CRON_COUNT). Consider cleaning up duplicates."
    fi
else
    print_status 1 "Cron job NOT found in root crontab"
    echo ""
    echo "To create the cron job, run:"
    echo "  cd $PROJECT_PATH"
    echo "  sudo crontab -e"
    echo "  # Add: 0 */24 * * * $SCRIPT_PATH >> $LOG_FILE 2>&1"
fi

# 4. Check Docker container
echo ""
echo "4. Checking Docker container..."
CONTAINER_NAME="docker-frappe-1"
if sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    print_status 0 "Container '$CONTAINER_NAME' is running"
    
    # Check if AWS CLI is available in container
    if sudo docker exec "$CONTAINER_NAME" bash -lc "command -v aws >/dev/null 2>&1"; then
        print_status 0 "AWS CLI is available in container"
        
        # Test AWS CLI version
        AWS_VERSION=$(sudo docker exec "$CONTAINER_NAME" bash -lc "aws --version 2>&1" || echo "error")
        if [[ "$AWS_VERSION" == *"aws-cli"* ]]; then
            print_status 0 "AWS CLI is working: $(echo $AWS_VERSION | head -1)"
        else
            print_status 1 "AWS CLI has issues: $AWS_VERSION"
            print_warning "Try fixing with: sudo docker exec $CONTAINER_NAME bash -lc \"pip3 install --user 'urllib3<2.0' --force-reinstall\""
        fi
    else
        print_status 1 "AWS CLI NOT found in container"
    fi
else
    print_status 1 "Container '$CONTAINER_NAME' is NOT running"
    echo "  Available containers:"
    sudo docker ps --format '  {{.Names}}' | head -5
fi

# 5. Check log file
echo ""
echo "5. Checking log file..."
if [ -f "$LOG_FILE" ]; then
    print_status 0 "Log file exists: $LOG_FILE"
    LOG_SIZE=$(sudo stat -f%z "$LOG_FILE" 2>/dev/null || sudo stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
    if [ "$LOG_SIZE" -gt 0 ]; then
        echo "  Log file size: $(numfmt --to=iec-i --suffix=B $LOG_SIZE 2>/dev/null || echo "${LOG_SIZE} bytes")"
        echo ""
        echo "  Last 10 lines of log:"
        echo "  ----------------------------------------"
        sudo tail -10 "$LOG_FILE" | sed 's/^/  /'
        echo "  ----------------------------------------"
    else
        print_warning "Log file is empty (cron job may not have run yet)"
    fi
else
    print_warning "Log file doesn't exist yet (will be created on first run)"
fi

# 6. Test script execution (dry run check)
echo ""
echo "6. Testing script prerequisites..."
echo "  Checking if script can read environment variables..."

# Source env file and check variables
set +u  # Allow unset variables for this check
if source "$ENV_FILE" 2>/dev/null; then
    if [ -n "${BUCKET_NAME:-}" ] && [ -n "${BUCKET_ACCESS_KEY_ID:-}" ]; then
        print_status 0 "Environment variables can be loaded"
    else
        print_status 1 "Environment variables are not properly set"
    fi
else
    print_status 1 "Cannot source environment file"
fi
set -u

# 7. Check cron service
echo ""
echo "7. Checking cron service..."
if systemctl is-active --quiet cron || systemctl is-active --quiet crond; then
    print_status 0 "Cron service is running"
else
    print_status 1 "Cron service is NOT running"
    echo "  Start with: sudo systemctl start cron"
fi

# Summary
echo ""
echo "=========================================="
echo "Verification Summary"
echo "=========================================="
echo ""
echo "To manually test the backup script:"
echo "  sudo $SCRIPT_PATH"
echo ""
echo "To monitor cron execution in real-time:"
echo "  sudo tail -f $LOG_FILE"
echo ""
echo "To view all cron jobs:"
echo "  sudo crontab -l"
echo ""
echo "To manually trigger the cron job:"
echo "  sudo $SCRIPT_PATH >> $LOG_FILE 2>&1"
echo ""

