#!/bin/bash
set -euo pipefail

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

echo "=== Fetching site files from S3 ==="
echo "Site: ${SITE_NAME}"
echo "Bucket: ${S3_BUCKET}"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is not installed or not in PATH" >&2
  exit 1
fi

# Ensure local directories exist
mkdir -p "${PRIVATE_DIR}" "${PUBLIC_DIR}" "${LOGS_DIR}"

# Sync helpers
sync_dir() {
  local s3_prefix="$1"   # e.g. "private" / "public" / "logs"
  local local_dir="$2"

  echo "Syncing s3://${S3_BUCKET}/${s3_prefix}/ -> ${local_dir}"
  aws s3 sync "s3://${S3_BUCKET}/${s3_prefix}/" "${local_dir}/" --no-progress || \
    echo "Warning: failed to sync prefix ${s3_prefix}; it may not exist yet" >&2
}

sync_dir "private" "${PRIVATE_DIR}"
sync_dir "public"  "${PUBLIC_DIR}"
sync_dir "logs"    "${LOGS_DIR}"

# Fix permissions (best-effort)
chown -R frappe:frappe "${SITE_DIR}" 2>/dev/null || true

echo "=== Fetch from bucket completed ==="