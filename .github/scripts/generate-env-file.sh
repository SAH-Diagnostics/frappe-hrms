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

# The file holds every deploy secret: create it owner-only. umask must be set BEFORE the
# truncation below, which is what creates the file; chmod covers a file that already existed
# with a wider mode (VC-657).
umask 077

# Clear output file
> "$OUTPUT_ENV_FILE"
chmod 600 "$OUTPUT_ENV_FILE"

# Required variables for Docker deployment.
# The deploy-scope AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION are
# intentionally NOT written to the box: nothing there reads them (backups use
# BUCKET_*), and the file is handed to `docker compose --env-file`, so every key
# in it is available to the container configuration.
REQUIRED_VARS=(
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
    "ADMIN_PASSWORD"
    "FRAPPE_ENCRYPTION_KEY"
    "SITE_NAME"
    "SITE_URL"
    "EXISTING_SITE"
    "UPDATE_CODE"
)

# Optional variables: passed through when present in the secret, otherwise docker-compose.yml
# supplies the default
OPTIONAL_VARS=(
    "FRAPPE_2FA_ENABLED"
    "FRAPPE_2FA_ROLES"
    "FRAPPE_2FA_ISSUER"
)


# Generate .env file with required variables
echo "Writing environment variables to $OUTPUT_ENV_FILE..."

# Read secrets file and create a temporary associative array
declare -A SECRETS_MAP

# Load secrets into map
# Split on the first '=' only. `IFS='=' read -r key value` drops a trailing '=' from the value
# under bash 5 (the runners), which truncates base64 secrets such as FRAPPE_ENCRYPTION_KEY.
while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    value=""
    [[ "$line" == *=* ]] && value="${line#*=}"
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
        echo "Error: Required variable $var is not set in $SECRETS_FILE — refusing to deploy with a missing secret" >&2
        exit 1
    fi
    
    # Write to .env file
    echo "${var}=${value}" >> "$OUTPUT_ENV_FILE"
done

OPTIONAL_WRITTEN=0
for var in "${OPTIONAL_VARS[@]}"; do
    value="${SECRETS_MAP[$var]}"
    if [ -n "$value" ]; then
        echo "${var}=${value}" >> "$OUTPUT_ENV_FILE"
        OPTIONAL_WRITTEN=$((OPTIONAL_WRITTEN + 1))
    fi
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
TOTAL_VARS=$((${#REQUIRED_VARS[@]} + 5 + OPTIONAL_WRITTEN))  # +5 for DB_* mapped variables
echo "Total variables written: $TOTAL_VARS"

exit 0

