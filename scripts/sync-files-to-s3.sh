#!/usr/bin/env bash

set -euo pipefail

# Path to the env file created by the GitHub Actions workflow
ENV_FILE="/opt/frappe-hrms/deploy/dev/.env.remote"

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/opt/frappe-hrms/deploy/dev/.env.remote
  set -a
  . "$ENV_FILE"
  set +a
fi

# SITE_NAME and BUCKET_NAME are expected from the env file, but provide safe fallbacks
SITE="${SITE_NAME:-dev-hrms.sahdiagnostics.com}"
BUCKET_NAME="${BUCKET_NAME:?BUCKET_NAME must be set in .env.remote}"

# AWS credentials & region from the same env file
AWS_KEY="${BUCKET_ACCESS_KEY_ID:?BUCKET_ACCESS_KEY_ID must be set in .env.remote}"
AWS_SECRET="${BUCKET_SECRET_ACCESS_KEY:?BUCKET_SECRET_ACCESS_KEY must be set in .env.remote}"
AWS_REGION="${BUCKET_REGION:-eu-west-2}"

CONTAINER_NAME="docker-frappe-1"

echo "=== Running file backup sync to S3 for site: ${SITE}, bucket: ${BUCKET_NAME} ==="

sudo docker exec "${CONTAINER_NAME}" bash -lc "
  set -euo pipefail
  export AWS_ACCESS_KEY_ID='${AWS_KEY}'
  export AWS_SECRET_ACCESS_KEY='${AWS_SECRET}'
  export AWS_DEFAULT_REGION='${AWS_REGION}'

  aws s3 sync \
    \"/home/frappe/frappe-bench/sites/${SITE}/private/files\" \
    \"s3://${BUCKET_NAME}/private/files\" \
    --delete

  aws s3 sync \
    \"/home/frappe/frappe-bench/sites/${SITE}/public/files\" \
    \"s3://${BUCKET_NAME}/public/files\" \
    --delete
"


