#!/bin/bash
set -e

# deploy-docker-app.sh
# Purpose: Deploy Docker application on remote instance
# Arguments:
#   $1 - REPO_URL (Git repository URL)
#   $2 - DEPLOY_DIR (deployment directory path, e.g., /opt/app)
#   $3 - ENV_FILE_SOURCE (path to .env file)
#   $4 - DOCKER_COMPOSE_FILE (docker-compose file name, default: docker-compose.yml)
#   $5 - lightsail_user
#   $6 - lightsail_host
#   $7 - lightsail_port
#   $8 - BRANCH_NAME (git branch to checkout, default: staging)
#   $9 - ssh_key_path

# Display help if arguments are missing
if [ $# -lt 7 ]; then
    echo "Usage: $0 <REPO_URL> <DEPLOY_DIR> <ENV_FILE_SOURCE> <DOCKER_COMPOSE_FILE> <lightsail_user> <lightsail_host> <lightsail_port> [BRANCH_NAME] [ssh_key_path]"
    echo "Purpose: Deploy Docker application on remote instance"
    exit 1
fi

REPO_URL="$1"
DEPLOY_DIR="$2"
ENV_FILE_SOURCE="$3"
DOCKER_COMPOSE_FILE="${4:-docker-compose.yml}"
LIGHTSAIL_USER="$5"
LIGHTSAIL_HOST="$6"
LIGHTSAIL_PORT="$7"
BRANCH_NAME="${8:-staging}"
SSH_KEY_PATH="${9:-~/.ssh/lightsail_key}"

# Expand ~ to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Deploying Docker application to $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$LIGHTSAIL_PORT"
echo "  Repository: $REPO_URL"
echo "  Deployment Directory: $DEPLOY_DIR"
echo "  Docker Compose File: $DOCKER_COMPOSE_FILE"
echo "  Branch: $BRANCH_NAME"

# Behavioural switches, read from the environment so the positional-argument contract
# used by the three deploy workflows stays unchanged.
#   ALLOW_DIRTY          discard on-box edits that differ from the target commit (see remote/sync-repo.sh)
#   HEALTHCHECK_URL      what the post-deploy check polls, from the box's point of view
#   HEALTHCHECK_TIMEOUT  seconds to wait; a from-scratch bench rebuild takes minutes
ALLOW_DIRTY="${ALLOW_DIRTY:-false}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://localhost:8000}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-900}"
echo "  Allow dirty tree: $ALLOW_DIRTY"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_OPTS=(-i "$SSH_KEY_PATH" -p "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new)
SSH_TARGET="$LIGHTSAIL_USER@$LIGHTSAIL_HOST"

# Step 1 - bring the checkout to origin/$BRANCH_NAME. Piped in as a real file rather than
# a heredoc so its $VARs belong to the remote shell and so it can be unit-tested locally.
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    ALLOW_DIRTY="$ALLOW_DIRTY" bash -s -- \
    "$DEPLOY_DIR" "$REPO_URL" "$BRANCH_NAME" "$ALLOW_DIRTY" \
    < "$SCRIPT_DIR/remote/sync-repo.sh"

# Step 2 - configure and start the stack.
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" << EOF
set -e

# Verify Docker and Docker Compose are available
echo "=== Verifying Docker and Docker Compose ==="
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed. Please run install-docker-dependencies.sh first"
    exit 1
fi

# Verify Docker Compose plugin is available
if ! docker compose version &> /dev/null 2>&1; then
    echo "Error: Docker Compose plugin is not available. Please run install-docker-dependencies.sh first"
    exit 1
fi

echo "✓ Using Docker Compose plugin"
docker compose version

echo "=== Installing .env file ==="
# Move, not copy: a copy left the secrets behind in the upload path (the user's home) after
# every deploy. umask 077 keeps anything this shell creates owner-only; chmod 600 fixes the
# mode of the moved file, which keeps whatever mode scp gave it (VC-657).
umask 077
mv -f $ENV_FILE_SOURCE $DEPLOY_DIR/.env
chmod 600 $DEPLOY_DIR/.env

echo "=== Fixing Docker volume permissions ==="
# Ensure Docker volumes have correct permissions for frappe user (UID 1000)
# This prevents permission errors when containers try to write to volumes
if [ -d "$DEPLOY_DIR" ]; then
    # Fix permissions on the deployment directory
    sudo chown -R $LIGHTSAIL_USER:$LIGHTSAIL_USER $DEPLOY_DIR 2>/dev/null || true
    # Create sites directory if it doesn't exist (for volume mount)
    sudo mkdir -p $DEPLOY_DIR/sites 2>/dev/null || true
    sudo chown -R 1000:1000 $DEPLOY_DIR/sites 2>/dev/null || true
    sudo chmod -R 755 $DEPLOY_DIR/sites 2>/dev/null || true
fi

echo "=== Deploying with Docker Compose ==="
cd $DEPLOY_DIR

# Before down: the first deploy with the site-data volume copies the running container's
# uploaded files into it, or they would be discarded with the container. stdin is this
# heredoc: without </dev/null anything in the seed that reads stdin eats the steps below.
bash $DEPLOY_DIR/.github/scripts/remote/seed-site-volume.sh $DEPLOY_DIR $DOCKER_COMPOSE_FILE < /dev/null

# Use docker compose (plugin) with explicit env file
sudo docker compose --env-file $DEPLOY_DIR/.env -f $DOCKER_COMPOSE_FILE down || true
sudo docker compose --env-file $DEPLOY_DIR/.env -f $DOCKER_COMPOSE_FILE up -d --build

echo "=== Verifying containers ==="
sleep 5
sudo docker compose -f $DOCKER_COMPOSE_FILE ps

# Container logs are NOT printed: this job's output is a public Actions log, and bench /
# init.sh output can carry credentials. On a failed verification, verify-site.sh writes them
# to a root-only file on the box instead (VC-657).
echo "Container logs are not echoed here; read them on the box with 'sudo docker compose logs'."

echo "✓ Containers started"
EOF

# Step 3 - containers being up is not the same as the site being up. The old script
# reported success here, which is how a stack that never served a request still produced
# a green deploy. `set -e` makes a failed verification fail the job.
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" bash -s -- \
    "$DEPLOY_DIR" "$DOCKER_COMPOSE_FILE" "$HEALTHCHECK_URL" "$HEALTHCHECK_TIMEOUT" \
    < "$SCRIPT_DIR/remote/verify-site.sh"

echo "✓ Docker application deployed and verified"

