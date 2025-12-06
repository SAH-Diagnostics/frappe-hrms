#!/bin/bash
set -e

# generate-env-file.sh
# Purpose: Generate .env file from provided variables
# Arguments:
#   $1 - SECRETS_FILE (input file containing KEY=VALUE pairs)
#   $2 - OUTPUT_ENV_FILE (output .env file path)

# Display help if arguments are missing
if [ $# -lt 2 ]; then
    echo "Usage: $0 <SECRETS_FILE> <OUTPUT_ENV_FILE>"
    echo "Purpose: Generate .env file from provided variables"
    exit 1
fi

SECRETS_FILE="$1"
OUTPUT_ENV_FILE="$2"

echo "Generating .env file from $SECRETS_FILE..."

# Verify secrets file exists
if [ ! -f "$SECRETS_FILE" ]; then
    echo "Error: Secrets file not found: $SECRETS_FILE"
    exit 1
fi

# Clear output file
> "$OUTPUT_ENV_FILE"

# Required variables for Docker deployment
REQUIRED_VARS=(
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
    "AWS_REGION"
    "BUCKET_ACCESS_KEY_ID"
    "BUCKET_SECRET_ACCESS_KEY"
    "BUCKET_ENDPOINT"
    "BUCKET_NAME"
    "BUCKET_REGION"
    "DATABASE_ENDPOINT"
    "DATABASE_NAME"
    "DATABASE_PASSWORD"
    "DATABASE_PORT"
    "DATABASE_USERNAME"
    "SITE_NAME"
    "SITE_URL"
    "EXISTING_SITE"
    "UPDATE_CODE"
)


# Generate .env file with required variables
echo "Writing environment variables to $OUTPUT_ENV_FILE..."

# Read secrets file and create a temporary associative array
declare -A SECRETS_MAP

# Load secrets into map
while IFS='=' read -r key value || [ -n "$key" ]; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    # Remove any quotes from value
    value="${value%\"}"
    value="${value#\"}"
    SECRETS_MAP["$key"]="$value"
done < "$SECRETS_FILE"

# Generate .env file with required variables
for var in "${REQUIRED_VARS[@]}"; do
    # Get the value from the map
    value="${SECRETS_MAP[$var]}"
    
    if [ -z "$value" ]; then
        echo "Warning: Variable $var is not set, using empty value"
        value=""
    fi
    
    # Write to .env file
    echo "${var}=${value}" >> "$OUTPUT_ENV_FILE"
done

# Map DATABASE_* variables to DB_* for docker-compose compatibility
if [ -n "${SECRETS_MAP[DATABASE_ENDPOINT]}" ]; then
    echo "DB_HOST=${SECRETS_MAP[DATABASE_ENDPOINT]}" >> "$OUTPUT_ENV_FILE"
fi
if [ -n "${SECRETS_MAP[DATABASE_PORT]}" ]; then
    echo "DB_PORT=${SECRETS_MAP[DATABASE_PORT]}" >> "$OUTPUT_ENV_FILE"
fi
if [ -n "${SECRETS_MAP[DATABASE_USERNAME]}" ]; then
    echo "DB_USER=${SECRETS_MAP[DATABASE_USERNAME]}" >> "$OUTPUT_ENV_FILE"
fi
if [ -n "${SECRETS_MAP[DATABASE_PASSWORD]}" ]; then
    echo "DB_PASSWORD=${SECRETS_MAP[DATABASE_PASSWORD]}" >> "$OUTPUT_ENV_FILE"
fi
if [ -n "${SECRETS_MAP[DATABASE_NAME]}" ]; then
    echo "DB_NAME=${SECRETS_MAP[DATABASE_NAME]}" >> "$OUTPUT_ENV_FILE"
fi

echo "✓ .env file generated successfully at $OUTPUT_ENV_FILE"
TOTAL_VARS=$((${#REQUIRED_VARS[@]} + 5))  # +5 for DB_* mapped variables
echo "Total variables written: $TOTAL_VARS"

exit 0

