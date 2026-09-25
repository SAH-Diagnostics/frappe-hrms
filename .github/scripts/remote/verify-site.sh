#!/usr/bin/env bash
#
# Assert that the site actually came up after a deploy.
#
# Runs ON the target box; the deploy job pipes it in with `ssh ... bash -s -- <args>`.
#
# Why this exists
# ---------------
# The deploy job previously reported success whenever `docker compose up -d` returned,
# which it does as soon as the containers are *started*. Nothing checked that the site
# ever answered. A container that exits on its first command, or a bench that fails
# halfway through provisioning, both produced a green deploy.
#
# The wait has to be generous. Only sites/<site> is on a volume, so `compose down && up` rebuilds
# the bench from scratch -- cloning frappe, erpnext, hrms and sah_crm and running migrate.
# That is minutes, not seconds. A short timeout here would turn a slow-but-healthy deploy
# into a red build, so the default window is 15 minutes and every attempt is announced.
#
# On failure it saves container status and logs to a root-only file ON THE BOX
# ($FAILURE_LOG_DIR/last-failure.log, dir 0700, file 0600) and prints only that path. It never
# prints the logs themselves: this output lands in a public GitHub Actions log, and bench /
# init.sh output can carry credentials (VC-657). The failure is still loud -- the job goes
# red and names the file to read -- so a deploy never fails silently.
#
# FAILURE_LOG_DIR is overridable only so the tests can point it at a temp dir.

set -uo pipefail

DEPLOY_DIR="${1:?DEPLOY_DIR is required}"
COMPOSE_FILE="${2:?COMPOSE_FILE is required}"
HEALTHCHECK_URL="${3:-http://localhost:8000}"
TIMEOUT_SECONDS="${4:-900}"
INTERVAL_SECONDS="${5:-15}"
FAILURE_LOG_DIR="${FAILURE_LOG_DIR:-/var/log/erp-deploy}"
FAILURE_LOG="$FAILURE_LOG_DIR/last-failure.log"

cd "$DEPLOY_DIR" || { echo "FATAL: $DEPLOY_DIR is not accessible." >&2; exit 1; }

# A site that answers can still be one deploy away from losing its data: stored secrets are
# encrypted with site_config's encryption_key, and site_config only survives the next
# `compose down` when the site directory is on the frappe-site-data volume. Prints one state
# word; never the key.
check_site_persistence() {
    local state
    state="$(sudo docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE" exec -T frappe python3 - 2>/dev/null <<'PY'
import json, os
site_dir = "/home/frappe/frappe-bench/sites/" + os.environ.get("SITE_NAME", "")
try:
    with open(site_dir + "/site_config.json") as f:
        current = json.load(f).get("encryption_key")
except Exception:
    print("unreadable")
    raise SystemExit
key = "match" if current and current == os.environ.get("ENCRYPTION_KEY") else "absent" if not current else "mismatch"
print(key + (":volume" if os.path.islink(site_dir) else ":no-volume"))
PY
)" || state="unreachable"

    if [ "$state" = "match:volume" ]; then
        echo "✓ encryption_key matches the deploy secret and the site directory is on the volume"
        return 0
    fi
    echo "FATAL: site persistence check failed (state: ${state:-empty})." >&2
    echo "Expected the pinned encryption_key and sites/<site> on the frappe-site-data volume;" >&2
    echo "without both, the next deploy loses stored secrets or uploaded files." >&2
    return 1
}

echo "=== Verifying site at $HEALTHCHECK_URL (up to ${TIMEOUT_SECONDS}s) ==="

elapsed=0
attempt=0
while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
    attempt=$((attempt + 1))

    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTHCHECK_URL" 2>&1)" || http_code="no-response"

    case "$http_code" in
        2??|3??)
            echo "attempt ${attempt} (${elapsed}s): HTTP ${http_code} -- site is up"
            check_site_persistence || exit 1
            echo "=== Site verified ==="
            exit 0
            ;;
        *)
            echo "attempt ${attempt} (${elapsed}s): ${http_code} -- not ready yet"
            ;;
    esac

    sleep "$INTERVAL_SECONDS"
    elapsed=$((elapsed + INTERVAL_SECONDS))
done

echo "FATAL: site did not respond at $HEALTHCHECK_URL within ${TIMEOUT_SECONDS}s." >&2
echo "The containers may be up while the application is not; the deploy is NOT healthy." >&2

# Create the dir 0700 and the file 0600 BEFORE any content is written to it, so the logs
# are never readable by another user, not even for an instant.
if sudo install -d -m 700 "$FAILURE_LOG_DIR" \
    && sudo touch "$FAILURE_LOG" \
    && sudo chmod 600 "$FAILURE_LOG"; then
    {
        echo "=== $(date -u +'%Y-%m-%dT%H:%M:%SZ') verify-site failure: $HEALTHCHECK_URL ==="
        echo "=== Container status ==="
        sudo docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE" ps 2>&1 || true
        echo "=== Last 100 log lines ==="
        sudo docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE" logs --tail=100 2>&1 || true
    } | sudo tee "$FAILURE_LOG" >/dev/null || true
    sudo chmod 600 "$FAILURE_LOG" || true
    echo "Container status and logs saved on the box to $FAILURE_LOG (root-only)." >&2
    echo "Read them there with: sudo cat $FAILURE_LOG" >&2
else
    echo "WARNING: could not create $FAILURE_LOG; logs were not saved." >&2
    echo "Read them on the box with: sudo docker compose --env-file $DEPLOY_DIR/.env -f $COMPOSE_FILE logs" >&2
fi

exit 1
