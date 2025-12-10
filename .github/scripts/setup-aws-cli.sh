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

# Validate inputs
echo "Validating input parameters..."

if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    echo "Error: AWS_ACCESS_KEY_ID (argument 1) is empty or not provided"
    echo "Hint: Check if the GitHub Secret 'STAGING_AWS_ACCESS_KEY_ID' is set"
    exit 1
fi

if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Error: AWS_SECRET_ACCESS_KEY (argument 2) is empty or not provided"
    echo "Hint: Check if the GitHub Secret 'STAGING_AWS_SECRETS_ACCESS_KEY' is set"
    exit 1
fi

if [ -z "$AWS_REGION" ]; then
    echo "Error: AWS_REGION (argument 3) is empty or not provided"
    echo "Hint: Check if the GitHub Secret 'AWS_SECRETS_REGION' is set"
    exit 1
fi

echo "✓ All input parameters validated"

echo "Setting up AWS CLI..."
echo "Region: $AWS_REGION"
echo "Access Key ID: ${AWS_ACCESS_KEY_ID:0:4}**** (masked)"

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

# Verify credentials were set (without showing values)
echo "Verifying credentials configuration..."
if aws configure get aws_access_key_id > /dev/null 2>&1; then
    echo "✓ Access key ID configured"
else
    echo "Error: Failed to set access key ID"
    exit 1
fi

if aws configure get aws_secret_access_key > /dev/null 2>&1; then
    echo "✓ Secret access key configured"
else
    echo "Error: Failed to set secret access key"
    exit 1
fi

if aws configure get default.region > /dev/null 2>&1; then
    echo "✓ Default region configured: $(aws configure get default.region)"
else
    echo "Error: Failed to set default region"
    exit 1
fi

# Test connection
echo "Testing AWS connection..."
IDENTITY_OUTPUT=$(aws sts get-caller-identity 2>&1)
IDENTITY_EXIT_CODE=$?

if [ $IDENTITY_EXIT_CODE -eq 0 ]; then
    echo "✓ AWS CLI configured successfully"
    echo "$IDENTITY_OUTPUT"
    exit 0
else
    echo "Error: Failed to authenticate with AWS"
    echo "AWS Error Details:"
    echo "$IDENTITY_OUTPUT"
    echo ""
    echo "Troubleshooting:"
    echo "  - Verify AWS_ACCESS_KEY_ID is correct"
    echo "  - Verify AWS_SECRET_ACCESS_KEY is correct"
    echo "  - Verify AWS_REGION is correct"
    echo "  - Check if credentials have necessary permissions (sts:GetCallerIdentity)"
    exit 1
fi

