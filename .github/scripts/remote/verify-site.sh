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
# The wait has to be generous. `sites/` is not a volume, so `compose down && up` rebuilds
# the bench from scratch -- cloning frappe, erpnext, hrms and sah_crm and running migrate.
# That is minutes, not seconds. A short timeout here would turn a slow-but-healthy deploy
# into a red build, so the default window is 15 minutes and every attempt is announced.
#
# On failure it prints container status and logs. It never discards stderr: a deploy that
# fails silently is the problem this script exists to solve.

set -uo pipefail

DEPLOY_DIR="${1:?DEPLOY_DIR is required}"
COMPOSE_FILE="${2:?COMPOSE_FILE is required}"
HEALTHCHECK_URL="${3:-http://localhost:8000}"
TIMEOUT_SECONDS="${4:-900}"
INTERVAL_SECONDS="${5:-15}"

cd "$DEPLOY_DIR" || { echo "FATAL: $DEPLOY_DIR is not accessible." >&2; exit 1; }

echo "=== Verifying site at $HEALTHCHECK_URL (up to ${TIMEOUT_SECONDS}s) ==="

elapsed=0
attempt=0
while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
    attempt=$((attempt + 1))

    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTHCHECK_URL" 2>&1)" || http_code="no-response"

    case "$http_code" in
        2??|3??)
            echo "attempt ${attempt} (${elapsed}s): HTTP ${http_code} -- site is up"
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

echo "=== Container status ===" >&2
sudo docker compose -f "$COMPOSE_FILE" ps >&2 || true

echo "=== Last 100 log lines ===" >&2
sudo docker compose -f "$COMPOSE_FILE" logs --tail=100 >&2 || true

exit 1
