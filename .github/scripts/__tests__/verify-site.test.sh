#!/usr/bin/env bash
#
# Tests for .github/scripts/remote/verify-site.sh
#
# Ticket: VC-657, Mask and hide secrets.
#
# Why this file exists
# --------------------
# verify-site.sh runs on the box at the end of every deploy, and its stdout and stderr land
# in the deploy job's log -- which is public for this repository. On a failed health check
# it used to print `docker compose logs --tail=100` straight into that log, and bench /
# init.sh output can carry credentials. It now saves status and logs to a root-only file on
# the box ($FAILURE_LOG_DIR/last-failure.log: dir 0700, file 0600) and prints only the path.
#
# `curl` always fails, `docker` prints a marker line on stdout AND stderr for every call,
# and `sudo` is a passthrough. The marker must never reach the script's own output, and
# must reach the file (so the test is not vacuous). FAILURE_LOG_DIR points at a temp dir.
# Nothing here touches a server, a container or the network.
#
# T9-T12 (VC-669): a site that answers must also have the files backup job installed, cron
# running, and a non-empty BUCKET_NAME, or the deploy goes red; FILES_BACK_UP_HOURS=off passes
# with a warning. T10 runs the in-container check itself against a fake cron file and /proc.
# T12 pins the snippet from before the bucket check and shows it passed a bucketless container.
#
# T7b-T8b, T13-T14 (VC-776): the site must be the volume mounted in place, not a symlink, and
# Frappe's scheduler must list the site and start a job after boot. T7b and T14 run the
# in-container Python against fixtures and a stand-in frappe package; T8b pins the pre-VC-776
# check and shows it passed a symlinked site. A pause in site_config warns and passes.
#
# Run:  bash .github/scripts/__tests__/verify-site.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../remote/verify-site.sh}"
# The last commit before VC-657 touched this script; used only by the anti-vacuity control.
PRE_FIX_REF="cd07d98c6b70000aaf0d7ca5ceed53fc8178228f"
MARKER="SECRET-LOG-LINE"

passed=0
failed=0

pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

check() { # description, expected, actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# GNU stat on the CI runner, BSD stat on macOS.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_stubs() { # $1 = stub dir, $2 = curl http code ("fail" = connection refused)
    mkdir -p "$1"
    cat > "$1/sudo" <<'STUB'
#!/usr/bin/env bash
if [ -n "${SUDO_FAILS_FOR:-}" ] && [ "$1" = "$SUDO_FAILS_FOR" ]; then
    echo "sudo: stubbed failure for $1" >&2
    exit 1
fi
exec "$@"
STUB
    cat > "$1/docker" <<'STUB'
#!/usr/bin/env bash
# The persistence check execs python3 in the container, the scheduler check execs the bench's
# env python, and the files backup check execs bash; answer each with the scenario's state.
echo "$*" >> "${DOCKER_LOG:-/dev/null}"
case " $* " in
    *" ps -q frappe "*)
        echo cid123
        exit 0
        ;;
    *" inspect "*)
        echo "${STARTED_AT-2026-11-24T10:00:00.123456789Z}"
        exit 0
        ;;
    *" exec "*"/env/bin/python "*)
        cat > /dev/null
        # SCHEDULER_STATES = space-separated answers, one per attempt; the last one repeats.
        n=$(( $(cat "$SCHED_COUNT" 2>/dev/null || echo 0) + 1 )); [ -n "${SCHED_COUNT:-}" ] && echo "$n" > "$SCHED_COUNT"
        set -- ${SCHEDULER_STATES:-advancing}; [ "$n" -gt "$#" ] && n=$#; shift $((n - 1))
        [ "$1" = "unreachable" ] && exit 1
        echo "$1"
        exit 0
        ;;
    *" exec "*" python3 "*)
        cat > /dev/null
        [ "${PERSISTENCE_STATE:-match:mount}" = "unreachable" ] && exit 1
        echo "${PERSISTENCE_STATE:-match:mount}"
        exit 0
        ;;
    *" exec "*" bash "*)
        cat > /dev/null
        [ "${BACKUP_STATE:-installed:running:set}" = "unreachable" ] && exit 1
        echo "${BACKUP_STATE:-installed:running:set}"
        exit 0
        ;;
esac
echo "SECRET-LOG-LINE stdout ($*)"
echo "SECRET-LOG-LINE stderr ($*)" >&2
exit 0
STUB
    if [ "$2" = "fail" ]; then
        cat > "$1/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect to localhost port 8000: Connection refused" >&2
exit 7
STUB
    else
        printf '#!/usr/bin/env bash\nprintf %%s %s\nexit 0\n' "$2" > "$1/curl"
    fi
    chmod +x "$1/sudo" "$1/docker" "$1/curl"
}

# $1 = script, $2 = stub dir, $3 = scenario dir. Leaves stdout/stderr/status in $3.
run_verify() {
    mkdir -p "$3/deploy"
    PATH="$2:$PATH" FAILURE_LOG_DIR="$3/var-log/erp-deploy" \
        SCHEDULER_TIMEOUT="${SCHEDULER_TIMEOUT:-0}" SCHEDULER_INTERVAL="${SCHEDULER_INTERVAL:-0}" \
        bash "$1" "$3/deploy" docker-compose.yml http://localhost:8000 2 1 \
        > "$3/stdout" 2> "$3/stderr"
    echo $? > "$3/status"
}

echo "Testing the post-deploy site check: $SCRIPT_UNDER_TEST"
echo

# ---------------------------------------------------------------------------
echo "T1: a failed health check keeps container logs out of the job output"
S1="$WORK/s1"; make_stubs "$S1/bin" fail
run_verify "$SCRIPT_UNDER_TEST" "$S1/bin" "$S1"
LOG1="$S1/var-log/erp-deploy/last-failure.log"
check "exited 1 (the deploy goes red)" 1 "$(cat "$S1/status")"
check "the log marker is not on stdout" 0 "$(grep -c "$MARKER" "$S1/stdout")"
check "the log marker is not on stderr" 0 "$(grep -c "$MARKER" "$S1/stderr")"
check "stderr names the failure-log path" 2 "$(grep -cF "$LOG1" "$S1/stderr")"
check "stderr still reports the failure (FATAL)" 1 "$(grep -c 'FATAL' "$S1/stderr")"
echo

# ---------------------------------------------------------------------------
echo "T2: the logs are saved to a root-only file on the box"
if [ -f "$LOG1" ]; then
    pass "failure log written at \$FAILURE_LOG_DIR/last-failure.log"
    check "failure log holds the container logs (non-vacuous)" 1 \
        "$(grep -cE "$MARKER stdout \\(compose --env-file [^ ]+/\\.env -f docker-compose\\.yml logs" "$LOG1")"
    check "failure log holds the container logs' stderr too" 1 \
        "$(grep -cE "$MARKER stderr \\(compose --env-file [^ ]+/\\.env -f docker-compose\\.yml logs" "$LOG1")"
    check "failure log holds the container status" 1 \
        "$(grep -cE "$MARKER stdout \\(compose --env-file [^ ]+/\\.env -f docker-compose\\.yml ps" "$LOG1")"
    check "failure log is mode 600" 600 "$(mode_of "$LOG1")"
    check "failure log dir is mode 700" 700 "$(mode_of "$(dirname "$LOG1")")"
else
    fail "no failure log at $LOG1"
fi
echo

# ---------------------------------------------------------------------------
echo "T3: if the log file cannot be created, the logs are still not printed"
S3="$WORK/s3"; make_stubs "$S3/bin" fail
SUDO_FAILS_FOR=install run_verify "$SCRIPT_UNDER_TEST" "$S3/bin" "$S3"
check "exited 1" 1 "$(cat "$S3/status")"
check "the log marker is not on stdout" 0 "$(grep -c "$MARKER" "$S3/stdout")"
check "the log marker is not on stderr" 0 "$(grep -c "$MARKER" "$S3/stderr")"
check "warned that the logs were not saved" 1 "$(grep -c 'WARNING: could not create' "$S3/stderr")"
echo

# ---------------------------------------------------------------------------
echo "T4: a healthy site exits 0 and writes no failure log"
S4="$WORK/s4"; make_stubs "$S4/bin" 200
run_verify "$SCRIPT_UNDER_TEST" "$S4/bin" "$S4"
check "exited 0" 0 "$(cat "$S4/status")"
check "reported the site up" 1 "$(grep -c 'Site verified' "$S4/stdout")"
if [ -e "$S4/var-log/erp-deploy/last-failure.log" ]; then
    fail "a failure log was written for a healthy deploy"
else
    pass "no failure log for a healthy deploy"
fi
echo

# ---------------------------------------------------------------------------
# T5 — anti-vacuity. The pre-fix script must print the marker under the same stubs,
#      proving T1 detects the real exposure. A missing ref is a FAILURE, not a skip.
echo "T5: the pre-fix script prints container logs into the job output (anti-vacuity control)"
BASE_SCRIPT="$WORK/pre-fix-verify-site.sh"
if git -C "$SCRIPT_DIR" show "$PRE_FIX_REF:.github/scripts/remote/verify-site.sh" > "$BASE_SCRIPT" 2>/dev/null; then
    S5="$WORK/s5"; make_stubs "$S5/bin" fail
    run_verify "$BASE_SCRIPT" "$S5/bin" "$S5"
    if grep -q "$MARKER" "$S5/stdout" "$S5/stderr"; then
        pass "pre-fix script leaks the container logs -- T1 detects the real bug"
    else
        fail "pre-fix script did not reproduce the leak; T1 may not be testing the fix"
    fi
else
    fail "could not read $PRE_FIX_REF:.github/scripts/remote/verify-site.sh -- the control did not run (fetch full history)"
fi
echo

# ---------------------------------------------------------------------------
# T6-T8 — the site must answer AND be one that survives the next deploy: the pinned
#          encryption_key in site_config.json, and sites/<site> being the frappe-site-data
#          volume mounted in place. A symlink is not enough (VC-776): Frappe's get_sites() skips
#          it, so the scheduler ran nothing for two months while this check passed.
echo "T6: a healthy site passes only with the pinned key and the volume mounted at the site"
for state in match:mount match:link match:no-volume mismatch:mount absent:mount unreadable:no-volume unreachable; do
    S6="$WORK/s6-${state//:/-}"; make_stubs "$S6/bin" 200
    PERSISTENCE_STATE="$state" run_verify "$SCRIPT_UNDER_TEST" "$S6/bin" "$S6"
    if [ "$state" = "match:mount" ]; then
        check "state $state: exited 0" 0 "$(cat "$S6/status")"
        check "state $state: reported the site verified" 1 "$(grep -c 'Site verified' "$S6/stdout")"
    else
        check "state $state: exited 1 (the deploy goes red)" 1 "$(cat "$S6/status")"
        check "state $state: stderr names the persistence failure" 1 \
            "$(grep -c 'FATAL: site persistence check failed' "$S6/stderr")"
        check "state $state: not reported as verified" 0 "$(grep -c 'Site verified' "$S6/stdout")"
    fi
done
echo

echo "T7: the check runs inside the frappe container with the deploy's env file"
check "COMPOSE carries the deploy env file" 1 \
    "$(grep -cxF 'COMPOSE=(sudo docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE")' "$SCRIPT_UNDER_TEST")"
if grep -qF '"${COMPOSE[@]}" exec -T frappe python3 -' "$SCRIPT_UNDER_TEST"; then
    pass "check execs python3 in the frappe service through COMPOSE"
else
    fail "check does not exec in the frappe service with the deploy env file"
fi
check "check never prints the key (only a state word)" 0 \
    "$(sed -n '/^check_site_persistence() {/,/^}/p' "$SCRIPT_UNDER_TEST" | grep -c 'print(current\|print(key)\|print(os.environ')"
echo

echo "T7b: the in-container persistence check tells a mount from a symlink and a plain folder"
PERSIST_PY="$(sed -n "/<<'PERSIST_PY'\$/,/^PERSIST_PY\$/p" "$SCRIPT_UNDER_TEST" | sed '1d;$d')"
if [ -z "$PERSIST_PY" ]; then
    fail "could not extract the persistence check from $SCRIPT_UNDER_TEST"
else
    P7="$(mkdir -p "$WORK/t7b" && cd "$WORK/t7b" && pwd -P)"
    KEY7="pinned-key"
    site_with_key() { mkdir -p "$1"; printf '{"encryption_key": "%s"}\n' "$2" > "$1/site_config.json"; }
    mountinfo_for() { echo "99 1 0:52 /volumes/x/_data/site.test $1 rw - ext4 /dev/root rw" > "$2"; }
    persist() { # $1 = site dir, $2 = mountinfo file
        env -i PATH=/usr/bin:/bin SITE_DIR="$1" MOUNTINFO="$2" ENCRYPTION_KEY="$KEY7" python3 - <<<"$PERSIST_PY"
    }
    site_with_key "$P7/mounted/site.test" "$KEY7"; mountinfo_for "$P7/mounted/site.test" "$P7/mi-mounted"
    check "mounted site with the pinned key" match:mount "$(persist "$P7/mounted/site.test" "$P7/mi-mounted")"
    site_with_key "$P7/vol/site.test" "$KEY7"; mkdir -p "$P7/linked"; ln -s "$P7/vol/site.test" "$P7/linked/site.test"
    mountinfo_for "$P7/linked/site.test" "$P7/mi-linked"
    check "symlinked site, even if listed as a mount" match:link "$(persist "$P7/linked/site.test" "$P7/mi-linked")"
    site_with_key "$P7/plain/site.test" "$KEY7"; mountinfo_for "$P7/other" "$P7/mi-plain"
    check "plain folder that is not a mount" match:no-volume "$(persist "$P7/plain/site.test" "$P7/mi-plain")"
    mkdir -p "$P7/real"; site_with_key "$P7/real/site.test" "$KEY7"; ln -s "$P7/real" "$P7/parent-link"
    mountinfo_for "$P7/parent-link/site.test" "$P7/mi-parent"
    check "site reached through a symlinked parent (public files would 404)" match:no-volume \
        "$(persist "$P7/parent-link/site.test" "$P7/mi-parent")"
    site_with_key "$P7/other-key/site.test" "not-the-pin"; mountinfo_for "$P7/other-key/site.test" "$P7/mi-ok"
    check "mounted site with a different key" mismatch:mount "$(persist "$P7/other-key/site.test" "$P7/mi-ok")"
    check "missing mountinfo is never read as mounted" match:no-volume "$(persist "$P7/mounted/site.test" "$P7/absent")"
    check "missing site_config" unreadable "$(persist "$P7/nowhere" "$P7/mi-mounted")"
fi
echo

# T8 — anti-vacuity: the script before this check reports a site with no volume as verified.
echo "T8: the pre-check script passes a site that is not on the volume (anti-vacuity control)"
PRE_CHECK_REF="3ed77774843049c521f8e867a7366e06e9020a39"
BASE8="$WORK/pre-check-verify-site.sh"
if git -C "$SCRIPT_DIR" show "$PRE_CHECK_REF:.github/scripts/remote/verify-site.sh" > "$BASE8" 2>/dev/null; then
    S8="$WORK/s8"; make_stubs "$S8/bin" 200
    PERSISTENCE_STATE="match:no-volume" run_verify "$BASE8" "$S8/bin" "$S8"
    check "pre-check script exits 0 for a site off the volume -- T6 detects the gap" 0 "$(cat "$S8/status")"
else
    fail "could not read $PRE_CHECK_REF:.github/scripts/remote/verify-site.sh -- the control did not run (fetch full history)"
fi
echo

# T8b — anti-vacuity: the script before the mount check called a SYMLINKED site healthy (its
#        word for it was "volume"), and had no scheduler check at all. That is the deploy that
#        stayed green from 25 Sep 2026 while no scheduled job ran.
echo "T8b: the pre-mount script passes a symlinked site the scheduler cannot see (anti-vacuity control)"
PRE_MOUNT_REF="bc53fd12174e3b8bec3ff18503b9d07d51732eb3"
BASE8B="$WORK/pre-mount-verify-site.sh"
if git -C "$SCRIPT_DIR" show "$PRE_MOUNT_REF:.github/scripts/remote/verify-site.sh" > "$BASE8B" 2>/dev/null; then
    S8B="$WORK/s8b"; make_stubs "$S8B/bin" 200
    PERSISTENCE_STATE="match:volume" SCHEDULER_STATES="invisible" run_verify "$BASE8B" "$S8B/bin" "$S8B"
    check "pre-mount script exits 0 for a symlinked, unscheduled site -- T6/T13 detect the gap" 0 "$(cat "$S8B/status")"
else
    fail "could not read $PRE_MOUNT_REF:.github/scripts/remote/verify-site.sh -- the control did not run (fetch full history)"
fi
echo

# ---------------------------------------------------------------------------
# T9-T11 (VC-669) — the files backup job. create-push-cron-job.sh only warns when it fails, so
#          the site comes up without it; verify-site.sh is where a deploy has to go red.
echo "T9: a healthy site passes only with the files backup job installed and cron running"
for state in installed:running:set off missing:running:set installed:stopped:set installed:running:unset missing:stopped:unset unreachable; do
    S9="$WORK/s9-${state//:/-}"; make_stubs "$S9/bin" 200
    BACKUP_STATE="$state" run_verify "$SCRIPT_UNDER_TEST" "$S9/bin" "$S9"
    case "$state" in
        installed:running:set|off)
            check "state $state: exited 0" 0 "$(cat "$S9/status")"
            check "state $state: reported the site verified" 1 "$(grep -c 'Site verified' "$S9/stdout")"
            ;;
        *)
            check "state $state: exited 1 (the deploy goes red)" 1 "$(cat "$S9/status")"
            check "state $state: stderr names the files backup failure" 1 \
                "$(grep -c 'FATAL: files backup check failed' "$S9/stderr")"
            check "state $state: not reported as verified" 0 "$(grep -c 'Site verified' "$S9/stdout")"
            ;;
    esac
done
check "state off: warns that files are deliberately not backed up" 1 \
    "$(grep -c 'deliberately NOT backed up' "$WORK/s9-off/stdout")"
echo

echo "T10: the in-container check reads the cron file and /proc correctly"
SNIPPET="$(sed -n "/exec -T frappe bash -s 2>\/dev\/null <<'SH'\$/,/^SH\$/p" "$SCRIPT_UNDER_TEST" | sed '1d;$d')"
if [ -z "$SNIPPET" ]; then
    fail "could not extract the in-container check from $SCRIPT_UNDER_TEST"
else
    T10="$WORK/t10"; mkdir -p "$T10/proc/101" "$T10/proc/102" "$T10/proc-nocron/101"
    echo bash > "$T10/proc/101/comm"; echo cron > "$T10/proc/102/comm"
    echo bash > "$T10/proc-nocron/101/comm"
    job() { printf 'SHELL=/bin/bash\nPATH=/usr/bin:/bin\n%s frappe /home/frappe/push-to-bucket.sh >> /x.log 2>&1\n' "$1"; }
    job "0 */1 * * *" > "$T10/hourly"; job "0 0 * * *" > "$T10/daily"
    printf 'SHELL=/bin/bash\n# 0 0 * * * frappe /home/frappe/push-to-bucket.sh\n' > "$T10/commented"
    in_container() { # $1 = cron file, $2 = proc dir, $3 = FILES_BACK_UP_HOURS, $4 = BUCKET_NAME
        env -i PATH=/usr/bin:/bin CRON_FILE="$1" PROC_DIR="$2" FILES_BACK_UP_HOURS="$3" BUCKET_NAME="${4-erp-bucket}" bash -s <<<"$SNIPPET"
    }
    check "hourly job, cron running" installed:running:set "$(in_container "$T10/hourly" "$T10/proc" 1)"
    check "daily job, cron running" installed:running:set "$(in_container "$T10/daily" "$T10/proc" 24)"
    check "no cron file" missing:running:set "$(in_container "$T10/absent" "$T10/proc" 1)"
    check "job only in a comment" missing:running:set "$(in_container "$T10/commented" "$T10/proc" 1)"
    check "job installed, cron not running" installed:stopped:set "$(in_container "$T10/hourly" "$T10/proc-nocron" 1)"
    check "FILES_BACK_UP_HOURS=off" off "$(in_container "$T10/absent" "$T10/proc-nocron" off)"
    check "BUCKET_NAME empty: the bucket is reported unset" installed:running:unset \
        "$(in_container "$T10/hourly" "$T10/proc" 1 "")"
    check "BUCKET_NAME empty and no job: both are reported" missing:running:unset \
        "$(in_container "$T10/absent" "$T10/proc" 1 "")"
    check "off short-circuits before the bucket is read" off \
        "$(in_container "$T10/hourly" "$T10/proc" off "")"
fi
echo

# T11 — anti-vacuity: the script before this check reports a site with no backup job as verified.
echo "T11: the pre-check script passes a site with no files backup job (anti-vacuity control)"
PRE_BACKUP_REF="bec5cbaf5de278698341a5644de9b7371a9bf507"
BASE11="$WORK/pre-backup-verify-site.sh"
if git -C "$SCRIPT_DIR" show "$PRE_BACKUP_REF:.github/scripts/remote/verify-site.sh" > "$BASE11" 2>/dev/null; then
    S11="$WORK/s11"; make_stubs "$S11/bin" 200
    # That script predates the mount check and speaks the old persistence word for "on the volume".
    PERSISTENCE_STATE="match:volume" BACKUP_STATE="missing:stopped" run_verify "$BASE11" "$S11/bin" "$S11"
    check "pre-check script exits 0 with no backup job -- T9 detects the gap" 0 "$(cat "$S11/status")"
else
    fail "could not read $PRE_BACKUP_REF:.github/scripts/remote/verify-site.sh -- the control did not run (fetch full history)"
fi
echo

# T12 — anti-vacuity: the snippet before the bucket check reports a container with no
#       BUCKET_NAME as installed:running, a state its own case() accepts, so the deploy went
#       green while every push FATALed into the log.
echo "T12: the pre-bucket-check snippet passes a container with no BUCKET_NAME (anti-vacuity control)"
PRE_BUCKET_REF="2a08c99a049449c0065d19c0fd68907ac74a15b0"
BASE12="$WORK/pre-bucket-verify-site.sh"
if git -C "$SCRIPT_DIR" show "$PRE_BUCKET_REF:.github/scripts/remote/verify-site.sh" > "$BASE12" 2>/dev/null; then
    SNIPPET12="$(sed -n "/exec -T frappe bash -s 2>\/dev\/null <<'SH'\$/,/^SH\$/p" "$BASE12" | sed '1d;$d')"
    got12="$(env -i PATH=/usr/bin:/bin CRON_FILE="$WORK/t10/hourly" PROC_DIR="$WORK/t10/proc"         FILES_BACK_UP_HOURS=1 BUCKET_NAME= bash -s <<<"$SNIPPET12")"
    check "pre-check snippet calls a bucketless container healthy -- T10 detects the gap"         installed:running "$got12"
else
    fail "could not read $PRE_BUCKET_REF:.github/scripts/remote/verify-site.sh -- the control did not run (fetch full history)"
fi
echo

# ---------------------------------------------------------------------------
# T13-T14 (VC-776) — the scheduler. After VC-644 the site answered and the deploy went green
#           while Frappe's scheduler skipped the site for two months: no inbox fetch, no email
#           queue, no HR jobs, no error anywhere.
echo "T13: a healthy site passes only when the scheduler sees it and a job has run since boot"
run_sched() { # $1 = scenario name; SCHEDULER_STATES / STARTED_AT / timeouts from the caller
    S13="$WORK/s13-$1"; make_stubs "$S13/bin" 200
    : > "$S13/count"
    SCHED_COUNT="$S13/count" DOCKER_LOG="$S13/docker.log" run_verify "$SCRIPT_UNDER_TEST" "$S13/bin" "$S13"
}
SCHEDULER_STATES="advancing" run_sched ok
check "advancing: exited 0" 0 "$(cat "$WORK/s13-ok/status")"
check "advancing: reported the site verified" 1 "$(grep -c 'Site verified' "$WORK/s13-ok/stdout")"
for state in invisible inactive stalled no-scheduler error unreachable; do
    SCHEDULER_STATES="$state" run_sched "$state"
    check "$state: exited 1 (the deploy goes red)" 1 "$(cat "$WORK/s13-$state/status")"
    check "$state: stderr names the scheduler failure" 1 \
        "$(grep -c "FATAL: scheduler check failed (state: $state)" "$WORK/s13-$state/stderr")"
    check "$state: not reported as verified" 0 "$(grep -c 'Site verified' "$WORK/s13-$state/stdout")"
done
# Retried states are polled until the timeout; a site Frappe cannot list fails at once.
SCHEDULER_TIMEOUT=2 SCHEDULER_INTERVAL=1 SCHEDULER_STATES="stalled" run_sched stalled-timeout
check "stalled: retried until the timeout (3 attempts)" 3 "$(cat "$WORK/s13-stalled-timeout/count")"
check "stalled: every attempt is announced" 3 "$(grep -c '^scheduler attempt ' "$WORK/s13-stalled-timeout/stdout")"
# One exec per attempt = one database connection per attempt, so no stale snapshot.
check "stalled: each attempt is a separate exec" 3 "$(grep -c ' exec .*/env/bin/python' "$WORK/s13-stalled-timeout/docker.log")"
SCHEDULER_TIMEOUT=5 SCHEDULER_INTERVAL=1 SCHEDULER_STATES="invisible" run_sched invisible-fast
check "invisible: fails on the first attempt, without waiting" 1 "$(cat "$WORK/s13-invisible-fast/count")"
SCHEDULER_TIMEOUT=5 SCHEDULER_INTERVAL=1 SCHEDULER_STATES="no-scheduler stalled advancing" run_sched recovers
check "a scheduler that catches up within the window: exited 0" 0 "$(cat "$WORK/s13-recovers/status")"
check "a scheduler that catches up within the window: 3 attempts" 3 "$(cat "$WORK/s13-recovers/count")"
# A deliberate pause in site_config (e.g. holding a backlog before release) warns but passes.
SCHEDULER_TIMEOUT=5 SCHEDULER_INTERVAL=1 SCHEDULER_STATES="paused" run_sched paused
check "paused: exited 0 (an operator hold does not fail the deploy)" 0 "$(cat "$WORK/s13-paused/status")"
check "paused: not polled again" 1 "$(cat "$WORK/s13-paused/count")"
check "paused: stderr warns that scheduled jobs will not run" 1 \
    "$(grep -c 'WARNING: the scheduler is paused in site_config' "$WORK/s13-paused/stderr")"
check "paused: the last line of the log repeats that it is still paused" 1 \
    "$(tail -1 "$WORK/s13-paused/stdout" | grep -c 'WARNING: the scheduler is still PAUSED')"
check "advancing: no paused warning" 0 "$(grep -c 'still PAUSED' "$WORK/s13-ok/stdout")"
# Anything the check prints that is not a known state word is logged and handled as 'error'.
SCHEDULER_TIMEOUT=0 SCHEDULER_STATES="Some-frappe-banner" run_sched unknown-word
check "unknown output: exited 1" 1 "$(cat "$WORK/s13-unknown-word/status")"
check "unknown output: logged as error, not echoed" 1 \
    "$(grep -c '^scheduler attempt 1 (0s): error$' "$WORK/s13-unknown-word/stdout")"
check "unknown output: never reaches the log" 0 "$(grep -c 'Some-frappe-banner' "$WORK/s13-unknown-word/stdout" "$WORK/s13-unknown-word/stderr" | awk -F: '{s+=$2} END {print s}')"
STARTED_AT="" SCHEDULER_STATES="advancing" run_sched no-container
check "no container start time: exited 1" 1 "$(cat "$WORK/s13-no-container/status")"
check "no container start time: names it" 1 "$(grep -c 'state: no-container' "$WORK/s13-no-container/stderr")"
check "the baseline passed in is the container's start time" 1 \
    "$(grep -c 'exec -T -e VERIFY_BASELINE=2026-11-24T10:00:00.123456789Z ' "$WORK/s13-ok/docker.log")"
check "the check uses the bench's python, which can import frappe" 1 \
    "$(grep -c -- '-w /home/frappe/frappe-bench/sites frappe /home/frappe/frappe-bench/env/bin/python -' "$WORK/s13-ok/docker.log")"
check "the scheduler log lines are state words only" 0 \
    "$(grep '^scheduler attempt ' "$WORK"/s13-*/stdout | grep -vcE ': (advancing|paused|invisible|inactive|stalled|no-scheduler|error|unreachable)$')"
echo

echo "T14: the in-container scheduler check reads Frappe correctly"
SCHED_PY="$(sed -n "/<<'SCHED_PY'\$/,/^SCHED_PY\$/p" "$SCRIPT_UNDER_TEST" | sed '1d;$d')"
if [ -z "$SCHED_PY" ]; then
    fail "could not extract the scheduler check from $SCRIPT_UNDER_TEST"
else
    # A stand-in frappe package: the real one needs a bench, a database and Redis. It exposes
    # exactly the calls the check makes, driven by FAKE_* variables.
    F14="$WORK/t14/fake"; mkdir -p "$F14/frappe/utils"
    cat > "$F14/frappe/__init__.py" <<'FAKE'
import os
class _DB:
    def sql(self, query):
        value = os.environ.get("FAKE_LAST")
        if "last_execution" not in query:
            raise RuntimeError("unexpected query")
        import datetime
        return [[datetime.datetime.fromisoformat(value) if value else None]]
db = _DB()
def init(site=None, sites_path=None):
    if os.environ.get("FAKE_RAISE") == "init":
        raise RuntimeError("db down")
def connect():
    pass
class _Conf:
    pause_scheduler = os.environ.get("FAKE_PAUSE") == "pause_scheduler"
    maintenance_mode = os.environ.get("FAKE_PAUSE") == "maintenance_mode"
class _Local:
    conf = _Conf()
local = _Local()
FAKE
    cat > "$F14/frappe/utils/__init__.py" <<'FAKE'
import datetime, os
def get_sites(sites_path=None):
    return os.environ.get("FAKE_SITES", "").split()
def convert_utc_to_system_timezone(ts):
    # System timezone fixed at UTC+1 (British Summer Time) to prove the conversion is applied.
    return ts.replace(tzinfo=datetime.timezone.utc).astimezone(datetime.timezone(datetime.timedelta(hours=1)))
FAKE
    cat > "$F14/frappe/utils/scheduler.py" <<'FAKE'
import os
def is_scheduler_inactive(verbose=True):
    if verbose:
        print("noise: maintenance mode")
    return os.environ.get("FAKE_INACTIVE") == "1"
def is_schduler_process_running():
    return os.environ.get("FAKE_RUNNING", "1") == "1"
FAKE
    sched() { # FAKE_* from the caller; container started 10:00:00 UTC = 11:00:00 system time
        env -i PATH=/usr/bin:/bin PYTHONPATH="$F14" SITE_NAME=site.test \
            VERIFY_BASELINE="2026-11-24T10:00:00.123456789Z" "$@" python3 - <<<"$SCHED_PY"
    }
    check "a job started after boot" advancing "$(sched FAKE_SITES="a site.test" FAKE_LAST=2026-11-24T11:03:00)"
    check "a job started exactly at boot" advancing "$(sched FAKE_SITES=site.test FAKE_LAST=2026-11-24T11:00:00)"
    check "last job before boot, in system time" stalled "$(sched FAKE_SITES=site.test FAKE_LAST=2026-11-24T10:59:00)"
    check "a UTC-vs-system-time mix-up would pass this; the check does not" stalled \
        "$(sched FAKE_SITES=site.test FAKE_LAST=2026-11-24T10:30:00)"
    check "no job has ever run" stalled "$(sched FAKE_SITES=site.test FAKE_LAST=)"
    check "Frappe does not list the site (symlinked)" invisible "$(sched FAKE_SITES="other.site" FAKE_LAST=2026-11-24T11:03:00)"
    check "scheduler disabled" inactive "$(sched FAKE_SITES=site.test FAKE_INACTIVE=1 FAKE_LAST=2026-11-24T11:03:00)"
    check "scheduler process not running" no-scheduler "$(sched FAKE_SITES=site.test FAKE_RUNNING=0 FAKE_LAST=2026-11-24T11:03:00)"
    check "pause_scheduler set in site_config" paused \
        "$(sched FAKE_SITES=site.test FAKE_PAUSE=pause_scheduler FAKE_INACTIVE=1 FAKE_LAST=)"
    check "maintenance_mode set in site_config" paused \
        "$(sched FAKE_SITES=site.test FAKE_PAUSE=maintenance_mode FAKE_INACTIVE=1 FAKE_LAST=)"
    check "a paused site Frappe cannot list is still invisible" invisible \
        "$(sched FAKE_SITES="other.site" FAKE_PAUSE=pause_scheduler FAKE_LAST=)"
    check "an exception becomes a state word, not a traceback" error "$(sched FAKE_SITES=site.test FAKE_RAISE=init 2>&1)"
fi
echo

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
