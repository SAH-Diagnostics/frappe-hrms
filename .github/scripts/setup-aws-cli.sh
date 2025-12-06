#!/bin/bash
set -e

# setup-aws-cli.sh
# Purpose: Configure and verify AWS CLI
# Arguments:
#   $1 - AWS_ACCESS_KEY_ID
#   $2 - AWS_SECRET_ACCESS_KEY
#   $3 - AWS_REGION

# Display help if arguments are missing
if [ $# -lt 3 ]; then
    echo "Usage: $0 <AWS_ACCESS_KEY_ID> <AWS_SECRET_ACCESS_KEY> <AWS_REGION>"
    echo "Purpose: Configure and verify AWS CLI"
    exit 1
fi

AWS_ACCESS_KEY_ID="$1"
AWS_SECRET_ACCESS_KEY="$2"
AWS_REGION="$3"

echo "Setting up AWS CLI..."

# Verify AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed"
    exit 1
fi

# Verify installation
echo "Verifying AWS CLI installation..."
aws --version

# Configure AWS CLI credentials
echo "Configuring AWS CLI credentials..."
aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
aws configure set default.region "$AWS_REGION"

# Test connection
echo "Testing AWS connection..."
if aws sts get-caller-identity > /dev/null 2>&1; then
    echo "✓ AWS CLI configured successfully"
    aws sts get-caller-identity
    exit 0
else
    echo "Error: Failed to authenticate with AWS"
    exit 1
fi

