#!/bin/bash
set -e

# setup-ssh.sh
# Purpose: Setup SSH connection for Lightsail instance
# Arguments:
#   $1 - lightsail_private_key_b64 (base64-encoded private key)
#   $2 - lightsail_host (IP address or hostname)
#   $3 - lightsail_user (SSH username)
#   $4 - lightsail_port (SSH port, default 22)

# Display help if arguments are missing
if [ $# -lt 3 ]; then
    echo "Usage: $0 <lightsail_private_key_b64> <lightsail_host> <lightsail_user> [lightsail_port]"
    echo "Purpose: Setup SSH connection for Lightsail instance"
    exit 1
fi

LIGHTSAIL_PRIVATE_KEY_B64="$1"
LIGHTSAIL_HOST="$2"
LIGHTSAIL_USER="$3"
LIGHTSAIL_PORT="${4:-22}"

echo "Setting up SSH connection to $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$LIGHTSAIL_PORT"

# Create .ssh directory if it doesn't exist
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Decode base64 private key and save to ~/.ssh/lightsail_key
echo "Decoding and saving SSH private key..."
echo "$LIGHTSAIL_PRIVATE_KEY_B64" | base64 -d > ~/.ssh/lightsail_key

# Set permissions to 600 on private key file
chmod 600 ~/.ssh/lightsail_key

# Add host to known_hosts
echo "Adding host to known_hosts..."
ssh-keyscan -H -p "$LIGHTSAIL_PORT" "$LIGHTSAIL_HOST" >> ~/.ssh/known_hosts 2>/dev/null || true

# Export SSH connection string as environment variable
export SSH_CONNECTION="ssh -i ~/.ssh/lightsail_key -p $LIGHTSAIL_PORT $LIGHTSAIL_USER@$LIGHTSAIL_HOST"

echo "✓ SSH connection configured successfully"
echo "SSH_CONNECTION=$SSH_CONNECTION"

exit 0

