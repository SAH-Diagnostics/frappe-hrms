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
#   $8 - ssh_key_path

# Display help if arguments are missing
if [ $# -lt 7 ]; then
    echo "Usage: $0 <REPO_URL> <DEPLOY_DIR> <ENV_FILE_SOURCE> <DOCKER_COMPOSE_FILE> <lightsail_user> <lightsail_host> <lightsail_port> [ssh_key_path]"
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
SSH_KEY_PATH="${8:-~/.ssh/lightsail_key}"

# Expand ~ to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Deploying Docker application to $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$LIGHTSAIL_PORT"
echo "  Repository: $REPO_URL"
echo "  Deployment Directory: $DEPLOY_DIR"
echo "  Docker Compose File: $DOCKER_COMPOSE_FILE"

# SSH into instance and execute deployment commands
ssh -i "$SSH_KEY_PATH" -p "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new "$LIGHTSAIL_USER@$LIGHTSAIL_HOST" << EOF
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

echo "=== Creating deployment directory ==="
sudo mkdir -p $DEPLOY_DIR
sudo chown $LIGHTSAIL_USER:$LIGHTSAIL_USER $DEPLOY_DIR

echo "=== Cloning or updating repository ==="
if [ -d "$DEPLOY_DIR/.git" ]; then
    echo "Repository exists, pulling latest changes..."
    cd $DEPLOY_DIR
    git fetch origin
    git checkout staging || git checkout -b staging origin/staging
    git pull origin staging
else
    echo "Cloning repository..."
    git clone $REPO_URL $DEPLOY_DIR
    cd $DEPLOY_DIR
    git checkout staging || git checkout -b staging origin/staging
fi

echo "=== Copying .env file ==="
cp $ENV_FILE_SOURCE $DEPLOY_DIR/.env
chmod 600 $DEPLOY_DIR/.env

echo "=== Deploying with Docker Compose ==="
cd $DEPLOY_DIR

# Use docker compose (plugin)
sudo docker compose -f $DOCKER_COMPOSE_FILE down || true
sudo docker compose -f $DOCKER_COMPOSE_FILE up -d --build

echo "=== Verifying containers ==="
sleep 5
sudo docker compose -f $DOCKER_COMPOSE_FILE ps

echo "=== Container logs (last 50 lines) ==="
sudo docker compose -f $DOCKER_COMPOSE_FILE logs --tail=50

echo "✓ Deployment completed successfully"
EOF

if [ $? -eq 0 ]; then
    echo "✓ Docker application deployed successfully"
    exit 0
else
    echo "Error: Deployment failed"
    exit 1
fi

