#!/bin/bash
set -e

# fetch-aws-secrets.sh
# Purpose: Retrieve secrets from AWS Secrets Manager and export as environment variables
# Arguments:
#   $1 - SECRET_ID (AWS Secrets Manager secret name)
#   $2 - OUTPUT_FILE (path to write environment variables)

# Display help if arguments are missing
if [ $# -lt 2 ]; then
    echo "Usage: $0 <SECRET_ID> <OUTPUT_FILE>"
    echo "Purpose: Retrieve secrets from AWS Secrets Manager and export as environment variables"
    exit 1
fi

SECRET_ID="$1"
OUTPUT_FILE="$2"

echo "Fetching secrets from AWS Secrets Manager: $SECRET_ID"

# Fetch secret JSON from AWS Secrets Manager
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text)

if [ -z "$SECRET_JSON" ]; then
    echo "Error: Failed to retrieve secret from AWS Secrets Manager"
    exit 1
fi

# Parse JSON and write to OUTPUT_FILE in KEY=VALUE format
echo "Parsing secrets and writing to $OUTPUT_FILE..."

# Clear output file
> "$OUTPUT_FILE"

# Parse JSON and extract key-value pairs
# Using Python for reliable JSON parsing (available in GitHub Actions runners)
if command -v python3 &> /dev/null; then
    # Use Python to parse JSON reliably
    # Write JSON to temp file to avoid shell expansion issues
    TEMP_JSON=$(mktemp)
    echo "$SECRET_JSON" > "$TEMP_JSON"
    
    python3 << PYTHON_EOF
import json
import sys
import os

try:
    # Read JSON from file
    with open("$TEMP_JSON", 'r') as f:
        secret_json = f.read()
    
    secrets = json.loads(secret_json)
    
    output_file = "$OUTPUT_FILE"
    with open(output_file, 'w') as f:
        for key, value in secrets.items():
            # Convert value to string
            value_str = str(value)
            # Mask sensitive values for GitHub Actions
            print(f"::add-mask::{value_str}")
            # Write to file
            f.write(f"{key}={value_str}\n")
    
    # Cleanup temp file
    os.remove("$TEMP_JSON")
    sys.exit(0)
except Exception as e:
    print(f"Error parsing JSON: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
    
    # Cleanup temp file if Python failed
    rm -f "$TEMP_JSON"
elif command -v jq &> /dev/null; then
    # Use jq to parse JSON
    echo "$SECRET_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"' | while IFS='=' read -r key value; do
        # Mask sensitive values for GitHub Actions
        echo "::add-mask::$value"
        echo "${key}=${value}" >> "$OUTPUT_FILE"
    done
else
    echo "Error: Neither python3 nor jq is available for JSON parsing"
    exit 1
fi

echo "✓ Secrets fetched and written to $OUTPUT_FILE"
echo "Total secrets extracted: $(wc -l < "$OUTPUT_FILE")"

exit 0

