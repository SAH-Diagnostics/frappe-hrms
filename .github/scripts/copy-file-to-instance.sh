#!/bin/bash
set -e

# copy-file-to-instance.sh
# Purpose: Copy file to Lightsail instance via SCP
# Arguments:
#   $1 - LOCAL_FILE (source file path)
#   $2 - REMOTE_PATH (destination path on instance)
#   $3 - lightsail_user
#   $4 - lightsail_host
#   $5 - lightsail_port
#   $6 - ssh_key_path (default: ~/.ssh/lightsail_key)

# Display help if arguments are missing
if [ $# -lt 5 ]; then
    echo "Usage: $0 <LOCAL_FILE> <REMOTE_PATH> <lightsail_user> <lightsail_host> <lightsail_port> [ssh_key_path]"
    echo "Purpose: Copy file to Lightsail instance via SCP"
    exit 1
fi

LOCAL_FILE="$1"
REMOTE_PATH="$2"
LIGHTSAIL_USER="$3"
LIGHTSAIL_HOST="$4"
LIGHTSAIL_PORT="$5"
SSH_KEY_PATH="${6:-~/.ssh/lightsail_key}"

# Expand ~ to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Copying file to Lightsail instance..."
echo "  Source: $LOCAL_FILE"
echo "  Destination: $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$REMOTE_PATH"

# Verify local file exists
if [ ! -f "$LOCAL_FILE" ]; then
    echo "Error: Local file not found: $LOCAL_FILE"
    exit 1
fi

# Verify SSH key exists
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Error: SSH key not found at $SSH_KEY_PATH"
    exit 1
fi

# Use SCP to copy file
if scp -i "$SSH_KEY_PATH" -P "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new "$LOCAL_FILE" "$LIGHTSAIL_USER@$LIGHTSAIL_HOST:$REMOTE_PATH" 2>&1; then
    echo "✓ File copied successfully"
    
    # Verify file was copied successfully by checking remote file
    if ssh -i "$SSH_KEY_PATH" -p "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new "$LIGHTSAIL_USER@$LIGHTSAIL_HOST" "test -f $REMOTE_PATH" 2>/dev/null; then
        echo "✓ File verified on remote instance"
        exit 0
    else
        echo "Warning: File copy completed but verification failed"
        exit 1
    fi
else
    echo "Error: Failed to copy file to instance"
    exit 1
fi

