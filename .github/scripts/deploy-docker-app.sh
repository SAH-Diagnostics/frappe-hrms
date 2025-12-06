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

echo "=== Installing/verifying Docker and Docker Compose ==="
sudo apt-get update
sudo apt-get install -y docker.io || true

# Install Docker Compose (try plugin first, fallback to standalone)
if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
    echo "Installing Docker Compose..."
    # Try to install docker-compose-plugin
    if sudo apt-get install -y docker-compose-plugin 2>/dev/null; then
        echo "✓ Docker Compose plugin installed"
    else
        # Fallback to standalone docker-compose
        echo "Installing standalone docker-compose..."
        DOCKER_COMPOSE_VERSION="v2.24.0"
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        ARCH=$(uname -m)
        # Map architecture names
        case "$ARCH" in
            x86_64) ARCH="x86_64" ;;
            aarch64) ARCH="aarch64" ;;
            armv7l) ARCH="armv7" ;;
            *) ARCH="x86_64" ;;
        esac
        sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-${OS}-${ARCH}" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        # Verify installation
        if docker-compose version &> /dev/null; then
            echo "✓ Standalone docker-compose installed successfully"
        else
            echo "Warning: docker-compose installation may have failed"
        fi
    fi
fi

sudo systemctl enable docker
sudo systemctl start docker

# Add user to docker group to avoid sudo (optional, but helpful)
sudo usermod -aG docker $LIGHTSAIL_USER || true

# Verify Docker Compose installation and determine which command to use
echo "Verifying Docker Compose installation..."
USE_DOCKER_COMPOSE_PLUGIN=false
if docker compose version &> /dev/null 2>&1; then
    echo "✓ Docker Compose plugin is available"
    USE_DOCKER_COMPOSE_PLUGIN=true
elif docker-compose version &> /dev/null 2>&1; then
    echo "✓ Standalone docker-compose is available"
    USE_DOCKER_COMPOSE_PLUGIN=false
else
    echo "Error: Docker Compose is not available"
    exit 1
fi

echo "=== Installing nginx and certbot ==="
sudo apt-get install -y nginx certbot python3-certbot-nginx || true

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

# Use the detected Docker Compose command
if [ "$USE_DOCKER_COMPOSE_PLUGIN" = "true" ]; then
    echo "Using: docker compose"
    sudo docker compose -f $DOCKER_COMPOSE_FILE down || true
    sudo docker compose -f $DOCKER_COMPOSE_FILE up -d --build
    
    echo "=== Verifying containers ==="
    sleep 5
    sudo docker compose -f $DOCKER_COMPOSE_FILE ps
    
    echo "=== Container logs (last 50 lines) ==="
    sudo docker compose -f $DOCKER_COMPOSE_FILE logs --tail=50
else
    echo "Using: docker-compose"
    sudo docker-compose -f $DOCKER_COMPOSE_FILE down || true
    sudo docker-compose -f $DOCKER_COMPOSE_FILE up -d --build
    
    echo "=== Verifying containers ==="
    sleep 5
    sudo docker-compose -f $DOCKER_COMPOSE_FILE ps
    
    echo "=== Container logs (last 50 lines) ==="
    sudo docker-compose -f $DOCKER_COMPOSE_FILE logs --tail=50
fi

echo "✓ Deployment completed successfully"
EOF

if [ $? -eq 0 ]; then
    echo "✓ Docker application deployed successfully"
    exit 0
else
    echo "Error: Deployment failed"
    exit 1
fi

