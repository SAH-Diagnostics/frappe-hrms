#!/bin/bash
set -euo pipefail

# Always run from /home/frappe so relative paths make sense (FRAPPE_HOME is for tests)
FRAPPE_HOME="${FRAPPE_HOME:-/home/frappe}"
cd "$FRAPPE_HOME" || exit 1

# One push at a time: a new container's first push uploads everything and can outlast the
# interval, and a manual run can overlap a scheduled one. Without flock, or if the lock file
# cannot be opened, the push runs unlocked rather than not at all.
PUSH_LOCK="${PUSH_LOCK:-/tmp/push-to-bucket.lock}"
if command -v flock >/dev/null 2>&1 && { exec 9>>"$PUSH_LOCK"; } 2>/dev/null; then
  if ! flock -n 9; then
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) Another push is still running; skipping this one ==="
    exit 0
  fi
fi

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
SITE_DIR="${FRAPPE_HOME}/frappe-bench/sites/${SITE_NAME}"
PRIVATE_DIR="${SITE_DIR}/private"
PUBLIC_DIR="${SITE_DIR}/public"
LOGS_DIR="${SITE_DIR}/logs"

# UTC timestamps: the log is the record of when each push ran.
echo "=== Pushing site files to S3 ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ==="
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

echo "=== Push to bucket completed ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ==="