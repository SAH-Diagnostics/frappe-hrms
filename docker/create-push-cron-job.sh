#!/bin/bash

set -euo pipefail

echo "=== create-push-cron-job.sh: configuring cron for push-to-bucket.sh ==="

# docker-compose.yml passes FILES_BACK_UP_HOURS. This script used to read FILES_BACKUP_HOURS,
# a name nothing sets, so the push was never scheduled and the S3 copy of uploaded files
# stopped at the last manual push (2026-04-02). The old spelling is still accepted.
HOURS="${FILES_BACK_UP_HOURS:-${FILES_BACKUP_HOURS:-}}"

# Overridable for tests (docker/__tests__/files-backup-cron.test.sh).
CRON_FILE="${CRON_FILE:-/etc/cron.d/frappe-files-backup}"
PUSH_LOG="${PUSH_LOG:-/var/log/push-to-bucket.log}"
PUSH_SCRIPT="${PUSH_SCRIPT:-/home/frappe/push-to-bucket.sh}"
INITIAL_PUSH="${INITIAL_PUSH:-1}"

if ! [[ "$HOURS" =~ ^[0-9]+$ ]] || [ "$HOURS" -lt 1 ] || [ "$HOURS" -gt 24 ]; then
  echo "WARNING: FILES_BACK_UP_HOURS is '${HOURS}', not a whole number of hours from 1 to 24."
  echo "WARNING: uploaded files are NOT being backed up to S3."
  exit 0
fi

if [ "$HOURS" -eq 24 ]; then
  CRON_SCHEDULE="0 0 * * *"
else
  CRON_SCHEDULE="0 */${HOURS} * * *"
fi

# The pinned frappe/bench image ships cron; install it if a later image does not.
if ! command -v cron >/dev/null 2>&1; then
  echo "Installing cron..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq cron
fi

# cron starts jobs with an empty environment and PATH=/usr/bin:/bin. The bucket settings are
# read from the container's environment by bucket-env.sh; PATH must reach /usr/local/bin/aws.
tmp="$(mktemp)"
{
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo "${CRON_SCHEDULE} frappe ${PUSH_SCRIPT} >> ${PUSH_LOG} 2>&1"
} > "$tmp"
echo "Creating cron file ${CRON_FILE} with schedule: ${CRON_SCHEDULE}"
sudo cp "$tmp" "$CRON_FILE"
sudo chmod 0644 "$CRON_FILE"
rm -f "$tmp"

sudo touch "$PUSH_LOG"
sudo chown frappe:frappe "$PUSH_LOG"

echo "Starting cron daemon..."
if ! sudo service cron start && ! sudo cron; then
  echo "WARNING: cron could not be started; uploaded files are NOT being backed up to S3."
  exit 0
fi

# Push once now rather than waiting for the first scheduled run, so a fresh container's
# files reach S3 straight away. In the background: bench must not wait for the upload.
if [ "$INITIAL_PUSH" = "1" ]; then
  echo "Starting a first push to S3 in the background; see ${PUSH_LOG}."
  nohup "$PUSH_SCRIPT" >> "$PUSH_LOG" 2>&1 < /dev/null &
fi

echo "=== create-push-cron-job.sh: cron configuration complete ==="
