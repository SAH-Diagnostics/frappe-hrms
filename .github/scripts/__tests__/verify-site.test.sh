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
# The persistence check execs python3 in the container and the files backup check execs bash;
# answer each with the scenario's state.
case " $* " in
    *" exec "*" python3 "*)
        cat > /dev/null
        [ "${PERSISTENCE_STATE:-match:volume}" = "unreachable" ] && exit 1
        echo "${PERSISTENCE_STATE:-match:volume}"
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
#          encryption_key in site_config.json, and sites/<site> on the frappe-site-data volume.
echo "T6: a healthy site passes only with the pinned key on the volume"
for state in match:volume mismatch:volume absent:volume match:no-volume unreadable:no-volume unreachable; do
    S6="$WORK/s6-${state//:/-}"; make_stubs "$S6/bin" 200
    PERSISTENCE_STATE="$state" run_verify "$SCRIPT_UNDER_TEST" "$S6/bin" "$S6"
    if [ "$state" = "match:volume" ]; then
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
if grep -qF 'sudo docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE" exec -T frappe python3 -' "$SCRIPT_UNDER_TEST"; then
    pass "check execs python3 in the frappe service with --env-file"
else
    fail "check does not exec in the frappe service with the deploy env file"
fi
check "check never prints the key (only a state word)" 0 \
    "$(sed -n '/^check_site_persistence() {/,/^}/p' "$SCRIPT_UNDER_TEST" | grep -c 'print(current\|print(key)\|print(os.environ')"
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
    BACKUP_STATE="missing:stopped" run_verify "$BASE11" "$S11/bin" "$S11"
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

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
