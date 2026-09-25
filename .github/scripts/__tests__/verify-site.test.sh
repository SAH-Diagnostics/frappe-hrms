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
# The persistence check execs python3 in the container; answer with the scenario's state.
case " $* " in
    *" exec "*)
        cat > /dev/null
        [ "${PERSISTENCE_STATE:-match:volume}" = "unreachable" ] && exit 1
        echo "${PERSISTENCE_STATE:-match:volume}"
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
        "$(grep -c "$MARKER stdout (compose -f docker-compose.yml logs" "$LOG1")"
    check "failure log holds the container logs' stderr too" 1 \
        "$(grep -c "$MARKER stderr (compose -f docker-compose.yml logs" "$LOG1")"
    check "failure log holds the container status" 1 \
        "$(grep -c "$MARKER stdout (compose -f docker-compose.yml ps" "$LOG1")"
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

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
