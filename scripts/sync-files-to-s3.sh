#!/usr/bin/env bash

set -euo pipefail

# Sync a site's private and public files from the frappe container to S3. Run from cron.
#
# The S3 credentials never touch this script's argv or environment (VC-657). They used to be
# read from the host env file and interpolated into the `bash -lc` string, so they sat in
# plain text on the `sudo` and `docker exec` command lines -- readable by any user on the
# box via `ps` / /proc/<pid>/cmdline while the sync ran. Now the payload is single-quoted and
# reads BUCKET_ACCESS_KEY_ID / BUCKET_SECRET_ACCESS_KEY / BUCKET_REGION from the CONTAINER's
# own environment (docker-compose.yml sets them). Only the non-secret SITE and BUCKET_NAME
# are passed in, as `docker exec -e NAME=value` arguments: `sudo` resets the environment,
# so `sudo -E` / inherited variables are not relied on.

# Path to the env file created by the GitHub Actions workflow. Overridable for tests.
ENV_FILE="${ENV_FILE:-/opt/frappe-hrms/deploy/dev/.env.remote}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

# SITE_NAME and BUCKET_NAME are expected from the env file, but provide safe fallbacks
SITE="${SITE_NAME:-dev-hrms.sahdiagnostics.com}"
BUCKET_NAME="${BUCKET_NAME:?BUCKET_NAME must be set in .env.remote}"

CONTAINER_NAME="docker-frappe-1"

echo "=== Running file backup sync to S3 for site: ${SITE}, bucket: ${BUCKET_NAME} ==="

# SC2016: the single quotes are the point -- every $VAR below expands inside the container.
# shellcheck disable=SC2016
sudo docker exec \
  -e "SITE=${SITE}" \
  -e "BUCKET_NAME=${BUCKET_NAME}" \
  "${CONTAINER_NAME}" bash -lc '
  set -euo pipefail
  : "${BUCKET_ACCESS_KEY_ID:?BUCKET_ACCESS_KEY_ID is not set in the container environment}"
  : "${BUCKET_SECRET_ACCESS_KEY:?BUCKET_SECRET_ACCESS_KEY is not set in the container environment}"
  export AWS_ACCESS_KEY_ID="$BUCKET_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$BUCKET_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION="${BUCKET_REGION:-eu-west-2}"

  aws s3 sync \
    "/home/frappe/frappe-bench/sites/${SITE}/private/files" \
    "s3://${BUCKET_NAME}/private/files" \
    --delete

  aws s3 sync \
    "/home/frappe/frappe-bench/sites/${SITE}/public/files" \
    "s3://${BUCKET_NAME}/public/files" \
    --delete
'
