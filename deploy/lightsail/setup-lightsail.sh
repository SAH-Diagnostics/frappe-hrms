#!/bin/bash

# Setup script for AWS Lightsail instance
# Run this script on your Lightsail instance to prepare it for deployment

set -e

echo "=== Frappe HRMS Lightsail Setup Script ==="
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    echo "Please run as normal user with sudo access, not as root"
    exit 1
fi

echo "This script will:"
echo "1. Update system packages"
echo "2. Install Docker and Docker Compose"
echo "3. Install and configure Nginx"
echo "4. Create necessary directories"
echo "5. Configure firewall rules"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# Update system
echo "=== Updating system packages ==="
sudo apt-get update
sudo apt-get upgrade -y

# Install required packages
echo "=== Installing required packages ==="
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    tar \
    git

# Install Docker
echo "=== Installing Docker ==="
if ! command -v docker &> /dev/null; then
    # Add Docker's official GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Add current user to docker group
    sudo usermod -aG docker $USER
    
    echo "✓ Docker installed successfully"
else
    echo "✓ Docker already installed"
fi

# Install Docker Compose (standalone)
echo "=== Installing Docker Compose ==="
if ! command -v docker-compose &> /dev/null; then
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
    sudo curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    echo "✓ Docker Compose installed successfully"
else
    echo "✓ Docker Compose already installed"
fi

# Install Nginx
echo "=== Installing Nginx ==="
if ! command -v nginx &> /dev/null; then
    sudo apt-get install -y nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
    echo "✓ Nginx installed successfully"
else
    echo "✓ Nginx already installed"
fi

# Create project directory
echo "=== Creating project directory ==="
PROJECT_DIR="/opt/frappe-hrms"
sudo mkdir -p $PROJECT_DIR
sudo chown $USER:$USER $PROJECT_DIR
echo "✓ Project directory created at $PROJECT_DIR"

# Configure firewall (Lightsail firewall is managed via console)
echo "=== Checking firewall ==="
if command -v ufw &> /dev/null; then
    sudo ufw allow OpenSSH
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable
    echo "✓ UFW firewall configured"
else
    echo "⚠ UFW not installed. Make sure Lightsail firewall allows ports 22, 80, and 443"
fi

# Configure Docker to start on boot
echo "=== Configuring Docker to start on boot ==="
sudo systemctl enable docker
sudo systemctl start docker

# Test Docker
echo "=== Testing Docker installation ==="
if docker --version && docker compose version; then
    echo "✓ Docker is working correctly"
else
    echo "✗ Docker test failed"
    exit 1
fi

# Remove default nginx site
echo "=== Configuring Nginx ==="
sudo rm -f /etc/nginx/sites-enabled/default

# Create log directory
sudo mkdir -p /var/log/nginx
sudo chown www-data:www-data /var/log/nginx

echo ""
echo "=== Setup completed successfully! ==="
echo ""
echo "Next steps:"
echo "1. Log out and log back in for Docker group membership to take effect"
echo "2. Add your SSH public key to ~/.ssh/authorized_keys if not already done"
echo "3. Update AWS Secrets Manager with your deployment credentials:"
echo "   - lightsail_host: $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
echo "   - lightsail_user: $USER"
echo "   - lightsail_port: 22"
echo "   - lightsail_private_key_b64: <base64 encoded SSH private key>"
echo "   - DATABASE_ENDPOINT: <your RDS/Lightsail MySQL endpoint>"
echo "   - DATABASE_NAME: frappe-db"
echo "   - DATABASE_USERNAME: dbmasteruser"
echo "   - DATABASE_PASSWORD: <your database password>"
echo "4. Configure GitHub secrets:"
echo "   - AWS_ACCESS_KEY_ID"
echo "   - AWS_SECRET_ACCESS_KEY"
echo "   - AWS_REGION"
echo "   - AWS_DEPLOY_SECRET_ID"
echo "5. Push to main branch to trigger deployment"
echo ""
echo "To verify the setup:"
echo "  docker --version"
echo "  docker compose version"
echo "  nginx -v"
echo ""

