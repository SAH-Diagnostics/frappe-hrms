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

COMPOSE=(sudo docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE")

# A site that answers can still be one deploy away from losing its data: stored secrets are
# encrypted with site_config's encryption_key, and site_config only survives the next
# `compose down` when the site directory is the frappe-site-data volume mounted in place.
# It must be a real mount, not a symlink: Frappe's get_sites() skips symlinked sites, so the
# scheduler runs nothing, and public files 404 because their path resolves outside the site
# (VC-776). Mount points come from mountinfo field 5, as in init.sh's assert_site_mount.
# Prints one state word; never the key. SITE_DIR and MOUNTINFO are overridable for the tests.
check_site_persistence() {
    local state
    state="$("${COMPOSE[@]}" exec -T frappe python3 - 2>/dev/null <<'PERSIST_PY'
import json, os
site_dir = os.environ.get("SITE_DIR") or "/home/frappe/frappe-bench/sites/" + os.environ.get("SITE_NAME", "")
mountinfo = os.environ.get("MOUNTINFO") or "/proc/self/mountinfo"
def mounted(path):
    try:
        with open(mountinfo) as f:
            return any(len(line.split()) > 4 and line.split()[4] == path for line in f)
    except OSError:
        return False
try:
    with open(site_dir + "/site_config.json") as f:
        current = json.load(f).get("encryption_key")
except Exception:
    print("unreadable")
    raise SystemExit
key = "match" if current and current == os.environ.get("ENCRYPTION_KEY") else "absent" if not current else "mismatch"
if os.path.islink(site_dir):
    where = "link"
elif os.path.realpath(site_dir) == site_dir and mounted(site_dir):
    where = "mount"
else:
    where = "no-volume"
print(key + ":" + where)
PERSIST_PY
)" || state="unreachable"

    if [ "$state" = "match:mount" ]; then
        echo "✓ encryption_key matches the deploy secret and the site directory is the mounted volume"
        return 0
    fi
    echo "FATAL: site persistence check failed (state: ${state:-empty})." >&2
    echo "Expected the pinned encryption_key and sites/<site> to be the frappe-site-data volume" >&2
    echo "mounted in place (not a symlink); otherwise the next deploy loses stored secrets or" >&2
    echo "uploaded files, or the scheduler cannot see the site." >&2
    return 1
}

# The scheduler skipped the site for two months after VC-644 and nothing went red: the site
# answered, so the deploy passed (VC-776). This checks that Frappe lists the site, that the
# scheduler is enabled and its process is running, and that a scheduled job has started since
# this container started -- `last_execution` is written by the worker when a job starts.
#
# Each attempt is a separate `exec`, so a separate database connection: one long-lived
# connection would keep reading one snapshot (MariaDB's default REPEATABLE READ isolation) and
# never see a new value.
# Each attempt prints a line, so the SSH session never idles. Prints state words only.
SCHEDULER_TIMEOUT="${SCHEDULER_TIMEOUT:-600}"
SCHEDULER_INTERVAL="${SCHEDULER_INTERVAL:-30}"
SCHEDULER_PAUSED=0
scheduler_state() { # $1 = container start time (UTC, RFC 3339)
    "${COMPOSE[@]}" exec -T -e VERIFY_BASELINE="$1" -w /home/frappe/frappe-bench/sites frappe \
        /home/frappe/frappe-bench/env/bin/python - 2>/dev/null <<'SCHED_PY'
import datetime, os
site = os.environ.get("SITE_NAME", "")
try:
    import frappe
    from frappe.utils import convert_utc_to_system_timezone, get_sites
    from frappe.utils.scheduler import is_schduler_process_running, is_scheduler_inactive
    if site not in get_sites(os.environ.get("SITES_PATH") or "."):
        print("invisible")
        raise SystemExit
    frappe.init(site=site, sites_path=os.environ.get("SITES_PATH") or ".")
    frappe.connect()
    if frappe.local.conf.pause_scheduler or frappe.local.conf.maintenance_mode:
        print("paused")
        raise SystemExit
    if is_scheduler_inactive(verbose=False):
        print("inactive")
        raise SystemExit
    if not is_schduler_process_running():
        print("no-scheduler")
        raise SystemExit
    started = datetime.datetime.fromisoformat(os.environ["VERIFY_BASELINE"][:19])
    baseline = convert_utc_to_system_timezone(started).replace(tzinfo=None)
    last = frappe.db.sql("select max(last_execution) from `tabScheduled Job Type`")[0][0]
    print("advancing" if last and last >= baseline else "stalled")
except SystemExit:
    raise
except Exception:
    print("error")
SCHED_PY
}

check_scheduler() {
    local started state elapsed=0 attempt=0
    started="$(sudo docker inspect -f '{{.State.StartedAt}}' "$("${COMPOSE[@]}" ps -q frappe 2>/dev/null)" 2>/dev/null)" || started=""
    if [ -z "$started" ]; then
        echo "FATAL: scheduler check failed (state: no-container)." >&2
        return 1
    fi

    while :; do
        attempt=$((attempt + 1))
        state="$(scheduler_state "$started")" || state="unreachable"
        case "$state" in
            advancing | paused | invisible | inactive | no-scheduler | stalled | error | unreachable) ;;
            *) state="error" ;;
        esac
        echo "scheduler attempt ${attempt} (${elapsed}s): ${state:-empty}"
        case "$state" in
            advancing)
                echo "✓ the scheduler sees the site and a scheduled job has run since the container started"
                return 0
                ;;
            paused)
                # pause_scheduler / maintenance_mode in site_config is an operator's deliberate
                # hold (e.g. to triage a queued backlog before release), so it does not fail the
                # deploy. The site is still checked to be visible above, which is the VC-776 bug.
                echo "WARNING: the scheduler is paused in site_config (pause_scheduler or maintenance_mode)." >&2
                echo "Scheduled jobs, inbox fetch and the email queue will not run until it is unset." >&2
                SCHEDULER_PAUSED=1
                return 0
                ;;
            invisible | inactive)
                break
                ;;
        esac
        [ "$elapsed" -ge "$SCHEDULER_TIMEOUT" ] && break
        sleep "$SCHEDULER_INTERVAL"
        elapsed=$((elapsed + SCHEDULER_INTERVAL))
    done

    echo "FATAL: scheduler check failed (state: ${state:-empty})." >&2
    echo "Expected Frappe to list the site (get_sites skips a symlinked site), the scheduler" >&2
    echo "enabled with its process running, and a Scheduled Job Type to start after boot." >&2
    echo "Without that, inbox fetch, the email queue and every scheduled job silently stop." >&2
    return 1
}

# Uploaded files reach S3 only through the cron job that docker/create-push-cron-job.sh installs
# at boot, and every failure there only warns so that the site still comes up. That is how the
# push went unscheduled for six months without anyone noticing (VC-669). init.sh runs that script
# before `bench start`, so by the time the site answers it has finished: this cannot race it.
# It proves the job is configured, not that a push has succeeded. FILES_BACK_UP_HOURS=off (a copy
# of the ERP deliberately run without the push, such as the VC-653 restore test) passes with a
# warning.
#
# BUCKET_NAME is checked here too. generate-env-file.sh already refuses to deploy without it,
# but that validates the secret on the runner; nothing checked that the value reached the
# container. Since bucket-env.sh now fails closed, a job installed without a bucket FATALs into
# the push log every hour and the deploy stays green -- the VC-669 shape again, one layer in.
# Prints one state word: job:cron:bucket, or "off".
check_files_backup() {
    local state
    state="$(sudo docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE" exec -T frappe bash -s 2>/dev/null <<'SH'
[ "$(printenv FILES_BACK_UP_HOURS)" = "off" ] && { echo off; exit 0; }
job=missing
cron=stopped
bucket=unset
grep -qE '^[0-9*/,-]+( [0-9*/,-]+){4} frappe ' "${CRON_FILE:-/etc/cron.d/frappe-files-backup}" 2>/dev/null && job=installed
for comm in "${PROC_DIR:-/proc}"/[0-9]*/comm; do
    [ "$(cat "$comm" 2>/dev/null)" = cron ] && { cron=running; break; }
done
[ -n "$(printenv BUCKET_NAME)" ] && bucket=set
echo "$job:$cron:$bucket"
SH
)" || state="unreachable"

    case "$state" in
        installed:running:set)
            echo "✓ the files backup job is installed, cron is running, and the bucket is set"
            return 0
            ;;
        off)
            echo "WARNING: FILES_BACK_UP_HOURS=off -- uploaded files are deliberately NOT backed up to S3."
            return 0
            ;;
    esac
    echo "FATAL: files backup check failed (state: ${state:-empty})." >&2
    echo "Expected job:cron:bucket = installed:running:set -- the cron file" >&2
    echo "/etc/cron.d/frappe-files-backup, a running cron, and a non-empty BUCKET_NAME in the" >&2
    echo "container. Without all three, uploaded files are not pushed to S3." >&2
    echo "create-push-cron-job.sh logs why at boot; bucket-env.sh refuses to guess a bucket." >&2
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
            check_scheduler || exit 1
            check_files_backup || exit 1
            echo "=== Site verified ==="
            # Repeated as the last line: a hold that is never lifted is the original incident.
            [ "$SCHEDULER_PAUSED" = 1 ] && echo "WARNING: the scheduler is still PAUSED -- unset pause_scheduler / maintenance_mode."
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
