#!/bin/bash
set -euo pipefail

# Always run from /home/frappe so relative paths make sense
cd /home/frappe || exit 1

# Load bucket + AWS env vars
if [ -f "./bucket-env.sh" ]; then
  # shellcheck source=/home/frappe/bucket-env.sh
  source "./bucket-env.sh"
else
  echo "bucket-env.sh not found in /home/frappe; cannot configure AWS credentials." >&2
  exit 1
fi

: "${S3_BUCKET:?S3_BUCKET (bucket name) must be set}"

SITE_NAME="${SITE_NAME:-hrms.localhost}"
SITE_DIR="/home/frappe/frappe-bench/sites/${SITE_NAME}"
PRIVATE_DIR="${SITE_DIR}/private"
PUBLIC_DIR="${SITE_DIR}/public"
LOGS_DIR="${SITE_DIR}/logs"

echo "=== Pushing site files to S3 ==="
echo "Site: ${SITE_NAME}"
echo "Bucket: ${S3_BUCKET}"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is not installed or not in PATH" >&2
  exit 1
fi

# Ensure directories exist locally
for d in "${PRIVATE_DIR}" "${PUBLIC_DIR}" "${LOGS_DIR}"; do
  if [ ! -d "${d}" ]; then
    echo "Local directory missing, creating: ${d}"
    mkdir -p "${d}"
  fi
done

# Sync helpers
sync_dir() {
  local local_dir="$1"
  local s3_prefix="$2"  # e.g. "private" / "public" / "logs"

  if [ ! -d "${local_dir}" ]; then
    echo "Skipping missing directory: ${local_dir}"
    return 0
  fi

  echo "Syncing ${local_dir} -> s3://${S3_BUCKET}/${s3_prefix}/"
  aws s3 sync "${local_dir}/" "s3://${S3_BUCKET}/${s3_prefix}/" --no-progress
}

sync_dir "${PRIVATE_DIR}" "private"
sync_dir "${PUBLIC_DIR}"  "public"
sync_dir "${LOGS_DIR}"    "logs"

echo "=== Push to bucket completed ==="