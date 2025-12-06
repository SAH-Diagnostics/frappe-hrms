#!/bin/bash
set -e

# install-docker-dependencies.sh
# Purpose: Install Docker and Docker Compose on remote instance
# Arguments:
#   $1 - lightsail_user
#   $2 - lightsail_host
#   $3 - lightsail_port
#   $4 - ssh_key_path (default: ~/.ssh/lightsail_key)

# Display help if arguments are missing
if [ $# -lt 3 ]; then
    echo "Usage: $0 <lightsail_user> <lightsail_host> <lightsail_port> [ssh_key_path]"
    echo "Purpose: Install Docker and Docker Compose on remote instance"
    exit 1
fi

LIGHTSAIL_USER="$1"
LIGHTSAIL_HOST="$2"
LIGHTSAIL_PORT="$3"
SSH_KEY_PATH="${4:-~/.ssh/lightsail_key}"

# Expand ~ to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Installing Docker and Docker Compose on $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$LIGHTSAIL_PORT"

# SSH into instance and install dependencies
ssh -i "$SSH_KEY_PATH" -p "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new "$LIGHTSAIL_USER@$LIGHTSAIL_HOST" << EOF
set -e

echo "=== Installing/verifying Docker ==="
sudo apt-get update

# Check if Docker is installed, if not install it
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    sudo apt-get install -y docker.io || true
fi

sudo systemctl enable docker
sudo systemctl start docker

# Add user to docker group to avoid sudo (optional, but helpful)
sudo usermod -aG docker $LIGHTSAIL_USER || true

# Verify Docker installation
echo "Verifying Docker installation..."
if docker --version &> /dev/null; then
    echo "✓ Docker installed successfully"
    docker --version
else
    echo "Error: Docker installation failed"
    exit 1
fi

echo "=== Installing Docker Compose ==="
DOCKER_COMPOSE_INSTALLED=false

# Check if Docker Compose is already available (with verbose output)
echo "Checking for existing Docker Compose installation..."

# Check for docker compose plugin first
if docker compose version 2>&1 | head -n 1 | grep -q "Docker Compose version"; then
    echo "✓ Docker Compose plugin is already installed"
    docker compose version
    DOCKER_COMPOSE_INSTALLED=true
# Check for standalone docker-compose
elif command -v docker-compose &> /dev/null; then
    echo "Found docker-compose command, testing version..."
    if docker-compose version 2>&1 | head -n 1 | grep -qE "(docker-compose version|Docker Compose version)"; then
        echo "✓ Standalone docker-compose is already installed"
        docker-compose version
        DOCKER_COMPOSE_INSTALLED=true
    else
        echo "docker-compose command exists but version check failed"
        echo "Output of 'docker-compose version':"
        docker-compose version 2>&1 || true
        echo "Removing broken docker-compose installation..."
        # Remove broken docker-compose binary from common locations
        sudo rm -f /usr/local/bin/docker-compose
        sudo rm -f /usr/bin/docker-compose
        sudo rm -f /usr/local/bin/docker-compose-v2
        DOCKER_COMPOSE_INSTALLED=false
    fi
else
    echo "Docker Compose not found"
    DOCKER_COMPOSE_INSTALLED=false
fi

# Install Docker Compose if not available (try multiple methods)
if [ "\$DOCKER_COMPOSE_INSTALLED" = "false" ]; then
    echo "Docker Compose not found, installing..."
    
    # Method 1: Try to install docker-compose-plugin from apt
    echo "Method 1: Trying apt package manager..."
    if sudo apt-get install -y docker-compose-plugin; then
        # Wait a moment for installation to complete
        sleep 2
        if docker compose version 2>&1 | head -n 1 | grep -qE "(Docker Compose version|docker compose version)"; then
            echo "✓ Docker Compose plugin installed via apt"
            docker compose version
            DOCKER_COMPOSE_INSTALLED=true
        else
            echo "Warning: docker-compose-plugin installed but 'docker compose version' failed"
            echo "Output:"
            docker compose version 2>&1 || true
        fi
    else
        echo "Method 1 failed: docker-compose-plugin not available in apt"
    fi
    
    # Method 2: Try installing from Docker's official repository
    if [ "\$DOCKER_COMPOSE_INSTALLED" = "false" ]; then
        echo "Method 2: Trying Docker's official repository..."
        sudo apt-get install -y ca-certificates curl gnupg lsb-release 2>/dev/null || true
        sudo install -m 0755 -d /etc/apt/keyrings 2>/dev/null || true
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg 2>/dev/null | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
        sudo chmod a+r /etc/apt/keyrings/docker.gpg 2>/dev/null || true
        echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null 2>/dev/null || true
        sudo apt-get update 2>/dev/null || true
        if sudo apt-get install -y docker-compose-plugin; then
            # Wait a moment for installation to complete
            sleep 2
            if docker compose version 2>&1 | head -n 1 | grep -qE "(Docker Compose version|docker compose version)"; then
                echo "✓ Docker Compose plugin installed from Docker repository"
                docker compose version
                DOCKER_COMPOSE_INSTALLED=true
            else
                echo "Warning: docker-compose-plugin installed but 'docker compose version' failed"
                echo "Output:"
                docker compose version 2>&1 || true
            fi
        else
            echo "Method 2 failed: Could not install docker-compose-plugin from Docker repository"
        fi
    fi
    
    # Method 3: Fallback to standalone docker-compose binary
    if [ "\$DOCKER_COMPOSE_INSTALLED" = "false" ]; then
        echo "Method 3: Downloading standalone docker-compose binary..."
        DOCKER_COMPOSE_VERSION="v2.24.5"
        OS=\$(uname -s | tr '[:upper:]' '[:lower:]')
        ARCH=\$(uname -m)
        
        # Map architecture names for docker-compose binary
        case "\$ARCH" in
            x86_64) DOCKER_ARCH="x86_64" ;;
            aarch64|arm64) DOCKER_ARCH="aarch64" ;;
            armv7l|armhf) DOCKER_ARCH="armv7" ;;
            *) DOCKER_ARCH="x86_64" ;;
        esac
        
        # Try to download docker-compose
        DOWNLOAD_URL="https://github.com/docker/compose/releases/download/\${DOCKER_COMPOSE_VERSION}/docker-compose-\${OS}-\${DOCKER_ARCH}"
        echo "Downloading from: \$DOWNLOAD_URL"
        
        # Download with proper error handling
        echo "Attempting download..."
        if sudo curl -L -f -o /usr/local/bin/docker-compose "\$DOWNLOAD_URL"; then
            echo "Download completed, setting permissions..."
            sudo chmod +x /usr/local/bin/docker-compose
            # Verify the file is a valid binary
            if [ -s /usr/local/bin/docker-compose ]; then
                if file /usr/local/bin/docker-compose | grep -q "ELF\|executable" || head -c 4 /usr/local/bin/docker-compose | grep -q "ELF"; then
                    echo "Binary file verified, testing version..."
                    if docker-compose version 2>&1 | head -n 1 | grep -qE "(docker-compose version|Docker Compose version)"; then
                        echo "✓ Standalone docker-compose downloaded and verified successfully"
                        docker-compose version
                        DOCKER_COMPOSE_INSTALLED=true
                    else
                        echo "Error: Binary downloaded but version check failed"
                        echo "Attempting to run: docker-compose version"
                        docker-compose version 2>&1 || true
                        echo "Removing failed binary..."
                        sudo rm -f /usr/local/bin/docker-compose
                    fi
                else
                    echo "Error: Downloaded file is not a valid binary"
                    sudo rm -f /usr/local/bin/docker-compose
                fi
            else
                echo "Error: Downloaded file is empty"
                sudo rm -f /usr/local/bin/docker-compose
            fi
        else
            echo "Error: Failed to download docker-compose from \$DOWNLOAD_URL"
            echo "Checking if file was partially downloaded..."
            if [ -f /usr/local/bin/docker-compose ]; then
                echo "Removing partial download..."
                sudo rm -f /usr/local/bin/docker-compose
            fi
        fi
    fi
    
    # Final verification
    if [ "\$DOCKER_COMPOSE_INSTALLED" = "false" ]; then
        echo ""
        echo "Error: All Docker Compose installation methods failed"
        echo "Attempted methods:"
        echo "  1. apt-get install docker-compose-plugin"
        echo "  2. Docker official repository"
        echo "  3. Standalone binary download"
        echo ""
        echo "Please check the error messages above and install Docker Compose manually on the server"
        exit 1
    else
        echo "✓ Docker Compose installation verified successfully"
    fi
fi

echo "=== Installing additional dependencies ==="
# Install nginx and certbot (needed for deployment)
sudo apt-get install -y nginx certbot python3-certbot-nginx || true

echo "✓ All dependencies installed successfully"
EOF

if [ $? -eq 0 ]; then
    echo "✓ Docker and Docker Compose installation completed successfully"
    exit 0
else
    echo "Error: Failed to install Docker dependencies"
    exit 1
fi

