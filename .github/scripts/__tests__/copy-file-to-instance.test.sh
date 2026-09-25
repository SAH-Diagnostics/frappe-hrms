#!/usr/bin/env bash
#
# Tests for .github/scripts/copy-file-to-instance.sh
#
# Ticket: VC-657, Mask and hide secrets.
#
# Why this file exists
# --------------------
# The deploy uploads the generated `.env` to the deploy user's home with this script, and a
# later step moves it into /opt/app with mode 0600. When the deploy aborts in between (e.g.
# sync-repo's dirty-tree check), the uploaded copy stays behind. scp keeps the mode of a
# file that already exists, so an old 0644 copy would stay world-readable. The script now
# removes the remote file before the scp, so scp creates it fresh with the source's mode.
#
# `ssh` and `scp` are stubs that append their call to a log. Nothing here touches a server
# or the network.
#
# Run:  bash .github/scripts/__tests__/copy-file-to-instance.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../copy-file-to-instance.sh}"
# The last commit before VC-657 touched this script; used only by the anti-vacuity control.
PRE_FIX_REF="cd07d98c6b70000aaf0d7ca5ceed53fc8178228f"
REMOTE_PATH="/home/deployer/.env"

passed=0
failed=0

pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_stubs() { # $1 = stub dir
    mkdir -p "$1"
    cat > "$1/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${*: -1}"
echo "ssh $cmd" >> "$CALL_LOG"
case "$cmd" in
    rm\ *) [ -z "${SSH_RM_FAILS:-}" ] || exit 1 ;;
esac
exit 0
STUB
    cat > "$1/scp" <<'STUB'
#!/usr/bin/env bash
echo "scp ${*: -1}" >> "$CALL_LOG"
exit 0
STUB
    chmod +x "$1/ssh" "$1/scp"
}

run_copy() { # $1 = script, $2 = stub dir, $3 = work dir; extra env passes through
    local src="$3/env-file" key="$3/key"
    : > "$src"; : > "$key"
    : > "$3/calls"
    CALL_LOG="$3/calls" PATH="$2:$PATH" \
        bash "$1" "$src" "$REMOTE_PATH" deployer host.invalid 22 "$key" > "$3/out" 2>&1
    echo $? > "$3/rc"
}

# ---------------------------------------------------------------------------
echo "T1: the remote file is removed before scp creates it"
S1="$WORK/s1"; make_stubs "$S1/bin"
run_copy "$SCRIPT_UNDER_TEST" "$S1/bin" "$S1"
if [ "$(cat "$S1/rc")" = 0 ]; then pass "copy succeeds"; else fail "copy failed: $(cat "$S1/out")"; fi
rm_line="$(grep -n "^ssh rm -f -- '$REMOTE_PATH'$" "$S1/calls" | head -1 | cut -d: -f1)"
scp_line="$(grep -n '^scp ' "$S1/calls" | head -1 | cut -d: -f1)"
if [ -n "$rm_line" ]; then pass "an rm of exactly the remote path is issued"; else fail "no rm of $REMOTE_PATH in: $(tr '\n' ';' < "$S1/calls")"; fi
if [ -n "$rm_line" ] && [ -n "$scp_line" ] && [ "$rm_line" -lt "$scp_line" ]; then
    pass "the rm runs before the scp"
else
    fail "rm (line ${rm_line:-none}) does not precede scp (line ${scp_line:-none})"
fi
echo

# ---------------------------------------------------------------------------
echo "T2: a failed rm aborts before anything is uploaded"
S2="$WORK/s2"; make_stubs "$S2/bin"
SSH_RM_FAILS=1 run_copy "$SCRIPT_UNDER_TEST" "$S2/bin" "$S2"
if [ "$(cat "$S2/rc")" != 0 ]; then pass "script exits non-zero"; else fail "script exited 0 after a failed rm"; fi
if grep -q '^scp ' "$S2/calls"; then fail "scp still ran after the failed rm"; else pass "scp did not run"; fi
echo

# ---------------------------------------------------------------------------
# T3 — anti-vacuity. The pre-fix script must scp without removing the file first, proving
#      T1 detects the real gap. A missing ref is a FAILURE, not a skip.
echo "T3: the pre-fix script uploads over the existing file (anti-vacuity control)"
BASE_SCRIPT="$WORK/pre-fix-copy-file-to-instance.sh"
if git -C "$SCRIPT_DIR" show "$PRE_FIX_REF:.github/scripts/copy-file-to-instance.sh" > "$BASE_SCRIPT" 2>/dev/null; then
    S3="$WORK/s3"; make_stubs "$S3/bin"
    run_copy "$BASE_SCRIPT" "$S3/bin" "$S3"
    if grep -q '^ssh rm ' "$S3/calls"; then
        fail "pre-fix script already removes the file; T1 may not be testing the fix"
    else
        pass "pre-fix script never removes the remote file -- T1 detects the real gap"
    fi
else
    fail "could not read $PRE_FIX_REF:.github/scripts/copy-file-to-instance.sh -- the control did not run (fetch full history)"
fi
echo

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
