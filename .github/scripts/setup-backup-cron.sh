#!/bin/bash
set -e

# setup-backup-cron.sh
# Purpose: Setup S3 backup cron job on remote instance
# Arguments:
#   $1 - SITE_URL
#   $2 - BUCKET_NAME
#   $3 - FILES_BACK_UP_HOURS
#   $4 - lightsail_user
#   $5 - lightsail_host
#   $6 - lightsail_port
#   $7 - ssh_key_path

# Display help if arguments are missing
if [ $# -lt 6 ]; then
    echo "Usage: $0 <SITE_URL> <BUCKET_NAME> <FILES_BACK_UP_HOURS> <lightsail_user> <lightsail_host> <lightsail_port> [ssh_key_path]"
    echo "Purpose: Setup S3 backup cron job on remote instance"
    exit 1
fi

SITE_URL="$1"
BUCKET_NAME="$2"
FILES_BACK_UP_HOURS="$3"
LIGHTSAIL_USER="$4"
LIGHTSAIL_HOST="$5"
LIGHTSAIL_PORT="$6"
SSH_KEY_PATH="${7:-~/.ssh/lightsail_key}"

# Expand ~ to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Setting up backup cron job on $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$LIGHTSAIL_PORT"
echo "  Site URL: $SITE_URL"
echo "  Bucket: $BUCKET_NAME"
echo "  Backup Frequency: Every $FILES_BACK_UP_HOURS hours"

# SSH into instance and setup backup cron job
ssh -i "$SSH_KEY_PATH" -p "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new "$LIGHTSAIL_USER@$LIGHTSAIL_HOST" << EOF
set -e

echo "=== Creating backup script directory ==="
sudo mkdir -p /opt/scripts

echo "=== Creating backup script ==="
sudo tee /opt/scripts/backup-files.sh > /dev/null << 'SCRIPT_EOF'
#!/bin/bash
set -e

# Load environment variables
source /opt/app/.env

# Configure AWS CLI
export AWS_ACCESS_KEY_ID=\$BUCKET_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=\$BUCKET_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=\$BUCKET_REGION

# Sync to S3
echo "Starting backup at \$(date)"
aws s3 sync /opt/app/sites/\$SITE_URL/private s3://\$BUCKET_NAME/private/ --endpoint-url=\$BUCKET_ENDPOINT || echo "Warning: Failed to sync private directory"
aws s3 sync /opt/app/sites/\$SITE_URL/public s3://\$BUCKET_NAME/public/ --endpoint-url=\$BUCKET_ENDPOINT || echo "Warning: Failed to sync public directory"

echo "Backup completed at \$(date)"
SCRIPT_EOF

echo "=== Setting script permissions ==="
sudo chmod +x /opt/scripts/backup-files.sh
sudo chown $LIGHTSAIL_USER:$LIGHTSAIL_USER /opt/scripts/backup-files.sh

echo "=== Configuring cron job ==="
CRON_JOB="0 */$FILES_BACK_UP_HOURS * * * /opt/scripts/backup-files.sh >> /var/log/backup.log 2>&1"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -Fq "/opt/scripts/backup-files.sh"; then
    echo "Cron job already exists, updating..."
    crontab -l 2>/dev/null | grep -v "/opt/scripts/backup-files.sh" | crontab - || true
fi

# Add cron job
(crontab -l 2>/dev/null; echo "\$CRON_JOB") | crontab -

echo "=== Verifying cron job ==="
crontab -l | grep backup-files.sh

echo "✓ Cron job configured successfully"
EOF

if [ $? -eq 0 ]; then
    echo "✓ Backup cron job setup completed successfully"
    exit 0
else
    echo "Error: Failed to setup backup cron job"
    exit 1
fi

