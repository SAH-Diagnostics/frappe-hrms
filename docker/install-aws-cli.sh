#!/bin/bash
set -e

echo "=== Installing AWS CLI ==="

# Check if AWS CLI is already installed
if command -v aws &> /dev/null; then
    echo "AWS CLI is already installed: $(aws --version)"
    exit 0
fi

echo "Installing AWS CLI..."

# Update package list and install dependencies (use sudo for apt-get)
sudo apt-get update -qq
sudo apt-get install -y -qq unzip curl

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
else
    echo "Unsupported architecture: $ARCH. Falling back to pip install."
    pip install awscli
    exit 0
fi

# Download and install AWS CLI
echo "Downloading AWS CLI for $ARCH..."
curl -f "$AWS_CLI_URL" -o "/tmp/awscliv2.zip" || {
    echo "Failed to download AWS CLI. Trying pip install as fallback..."
    pip install awscli
    exit 0
}

echo "Extracting and installing AWS CLI..."
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# Verify installation
if command -v aws &> /dev/null; then
    echo "✓ AWS CLI installed successfully: $(aws --version)"
else
    echo "✗ AWS CLI installation failed. Trying pip install as fallback..."
    pip install awscli
    if command -v aws &> /dev/null; then
        echo "✓ AWS CLI installed via pip: $(aws --version)"
    else
        echo "✗ AWS CLI installation failed completely"
        exit 1
    fi
fi
