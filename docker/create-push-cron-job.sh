#!/bin/bash

set -euo pipefail

echo "=== create-push-cron-job.sh: configuring cron for push-to-bucket.sh ==="

# Ensure FILES_BACKUP_HOURS is a positive integer
if [ -z "${FILES_BACKUP_HOURS:-}" ] || ! [[ "${FILES_BACKUP_HOURS}" =~ ^[0-9]+$ ]] || [ "${FILES_BACKUP_HOURS}" -le 0 ]; then
  echo "FILES_BACKUP_HOURS is not set to a positive integer; skipping cron setup for push-to-bucket.sh"
  exit 0
fi

CRON_FILE="/etc/cron.d/frappe-files-backup"
CRON_SCHEDULE="0 */${FILES_BACKUP_HOURS} * * *"

echo "Creating cron file ${CRON_FILE} with schedule: ${CRON_SCHEDULE}"
echo "${CRON_SCHEDULE} frappe /home/frappe/push-to-bucket.sh >> /var/log/push-to-bucket.log 2>&1" > "${CRON_FILE}"
chmod 0644 "${CRON_FILE}" 2>/dev/null || true
touch /var/log/push-to-bucket.log 2>/dev/null || true

echo "Starting cron daemon (best-effort)..."
if command -v service >/dev/null 2>&1; then
  service cron start 2>/dev/null || service crond start 2>/dev/null || true
elif command -v cron >/dev/null 2>&1; then
  cron || true
elif command -v crond >/dev/null 2>&1; then
  crond || true
else
  echo "Warning: cron daemon not found; push-to-bucket.sh will not run automatically."
fi

echo "=== create-push-cron-job.sh: cron configuration complete ==="
