#!/bin/bash
set -e

# test-ssh-connection.sh
# Purpose: Test SSH connectivity to Lightsail instance
# Arguments:
#   $1 - lightsail_user
#   $2 - lightsail_host
#   $3 - lightsail_port
#   $4 - ssh_key_path (default: ~/.ssh/lightsail_key)

# Display help if arguments are missing
if [ $# -lt 3 ]; then
    echo "Usage: $0 <lightsail_user> <lightsail_host> <lightsail_port> [ssh_key_path]"
    echo "Purpose: Test SSH connectivity to Lightsail instance"
    exit 1
fi

LIGHTSAIL_USER="$1"
LIGHTSAIL_HOST="$2"
LIGHTSAIL_PORT="$3"
SSH_KEY_PATH="${4:-~/.ssh/lightsail_key}"

# Expand ~ to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Testing SSH connection to $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$LIGHTSAIL_PORT..."

# Verify SSH key exists
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Error: SSH key not found at $SSH_KEY_PATH"
    exit 1
fi

# Execute test command
if ssh -i "$SSH_KEY_PATH" -p "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$LIGHTSAIL_USER@$LIGHTSAIL_HOST" "echo 'SSH Connection successful'" 2>&1; then
    echo "✓ SSH connection successful"
    echo "Connection details:"
    echo "  User: $LIGHTSAIL_USER"
    echo "  Host: $LIGHTSAIL_HOST"
    echo "  Port: $LIGHTSAIL_PORT"
    exit 0
else
    echo "Error: Failed to establish SSH connection"
    exit 1
fi

