#!/usr/bin/env bash
#
# Tests for scripts/sync-files-to-s3.sh
#
# Ticket: VC-657, Mask and hide secrets.
#
# Why this file exists
# --------------------
# The backup cron read the S3 key pair from the host env file and spliced it into the
# `bash -lc "..."` string handed to `sudo docker exec`. Both values therefore sat in plain
# text on the sudo and docker command lines, readable by any user on the box through `ps`
# or /proc/<pid>/cmdline for as long as the sync ran.
#
# The fixed script single-quotes the payload so the keys are expanded INSIDE the container,
# from the container's own BUCKET_* environment, and passes only the non-secret SITE and
# BUCKET_NAME in, as `docker exec -e NAME=value` arguments (sudo resets the environment, so
# nothing may rely on inheritance).
#
# `sudo` is a passthrough stub. `docker` is a stub that records its argv and then emulates
# `docker exec`: it runs the payload in a clean environment holding only the container's
# variables plus the `-e` ones, with a stub `aws` that records what it received. Nothing
# here touches a container, AWS or the network. The fixture values are dummies that do not
# look like AWS keys, so the repo's own credential scans stay quiet.
#
# Run:  bash scripts/__tests__/sync-files-to-s3.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../sync-files-to-s3.sh}"
# The last commit before VC-657 touched this script; used only by the anti-vacuity control.
PRE_FIX_REF="cd07d98c6b70000aaf0d7ca5ceed53fc8178228f"

passed=0
failed=0

pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

check() { # description, expected, actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HOST_KEY_ID="host-side-key-id-dummy"
HOST_SECRET="host-side-secret-dummy"
CONTAINER_KEY_ID="container-side-key-id-dummy"
CONTAINER_SECRET="container-side-secret-dummy"
SITE_VALUE="erp.example.invalid"
BUCKET_VALUE="dummy-backup-bucket"

cat > "$WORK/env.remote" <<EOF
SITE_NAME=$SITE_VALUE
BUCKET_NAME=$BUCKET_VALUE
BUCKET_ACCESS_KEY_ID=$HOST_KEY_ID
BUCKET_SECRET_ACCESS_KEY=$HOST_SECRET
BUCKET_REGION=eu-west-2
EOF

STUB_BIN="$WORK/bin"
export STUB_BIN
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/sudo" <<'STUB'
#!/usr/bin/env bash
# Records its own argv too: a secret on sudo's command line is just as visible in ps.
printf '%s\n' "$@" >> "$REC/sudo.argv"
exec "$@"
STUB

cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$REC/docker.argv"
[ "$1" = "exec" ] || { echo "stub docker: unexpected call: $*" >&2; exit 2; }
shift
envs=()
while [ "${1:-}" = "-e" ]; do envs+=("$2"); shift 2; done
echo "$1" > "$REC/container"
shift
# Emulate the container: only its own variables plus the -e ones. `bash -lc` becomes
# `bash -c` so no login profile can put a real aws CLI ahead of the stub.
[ "$1" = "bash" ] && [ "$2" = "-lc" ] || { echo "stub docker: expected 'bash -lc'" >&2; exit 2; }
exec env -i PATH="$STUB_BIN:/usr/bin:/bin" REC="$REC" \
    BUCKET_ACCESS_KEY_ID="$CONTAINER_KEY_ID" \
    BUCKET_SECRET_ACCESS_KEY="$CONTAINER_SECRET" \
    BUCKET_REGION=eu-west-2 \
    "${envs[@]}" bash -c "$3"
STUB

cat > "$STUB_BIN/aws" <<'STUB'
#!/usr/bin/env bash
{
    echo "ARGS=$*"
    echo "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID-<unset>}"
    echo "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY-<unset>}"
    echo "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION-<unset>}"
} >> "$REC/aws.log"
exit 0
STUB
chmod +x "$STUB_BIN/sudo" "$STUB_BIN/docker" "$STUB_BIN/aws"

# $1 = script to run, $2 = record dir. Prints the script's combined output.
run_sync() {
    mkdir -p "$2"
    : > "$2/docker.argv"; : > "$2/sudo.argv"; : > "$2/aws.log"
    PATH="$STUB_BIN:$PATH" REC="$2" ENV_FILE="$WORK/env.remote" \
        CONTAINER_KEY_ID="$CONTAINER_KEY_ID" CONTAINER_SECRET="$CONTAINER_SECRET" \
        bash "$1" 2>&1
}

echo "Testing the S3 file-sync cron: $SCRIPT_UNDER_TEST"
echo

# ---------------------------------------------------------------------------
echo "T1: the sync runs and the stubs were exercised (non-vacuous)"
REC1="$WORK/rec1"
T1_OUT="$(run_sync "$SCRIPT_UNDER_TEST" "$REC1")"; T1_STATUS=$?
check "exited 0" 0 "$T1_STATUS"
check "docker exec was called once" 1 "$(grep -cx 'exec' "$REC1/docker.argv")"
check "targeted the frappe container" "docker-frappe-1" "$(cat "$REC1/container" 2>/dev/null)"
check "aws s3 sync ran for private and public files" 2 "$(grep -c '^ARGS=s3 sync' "$REC1/aws.log")"
[ "$T1_STATUS" -eq 0 ] || echo "  output: $(tr '\n' ' ' <<<"$T1_OUT")"
echo

# ---------------------------------------------------------------------------
echo "T2: no S3 key value appears on the sudo or docker command line"
for v in "$HOST_KEY_ID" "$HOST_SECRET" "$CONTAINER_KEY_ID" "$CONTAINER_SECRET"; do
    check "'$v' is not in the recorded argv" 0 "$(cat "$REC1/sudo.argv" "$REC1/docker.argv" | grep -cF -- "$v")"
done
check "the script's own output does not print a key" 0 \
    "$(printf '%s\n' "$T1_OUT" | grep -cF -e "$HOST_KEY_ID" -e "$HOST_SECRET")"
echo

# ---------------------------------------------------------------------------
echo "T3: only the non-secret SITE and BUCKET_NAME are passed in, via docker exec -e"
check "passes -e SITE=<site>" 1 "$(grep -cxF "SITE=$SITE_VALUE" "$REC1/docker.argv")"
check "passes -e BUCKET_NAME=<bucket>" 1 "$(grep -cxF "BUCKET_NAME=$BUCKET_VALUE" "$REC1/docker.argv")"
check "passes no other -e variable" 2 "$(grep -cx -- '-e' "$REC1/docker.argv")"
# shellcheck disable=SC2016
check "the payload reads the key from the container env (literal \$BUCKET_ACCESS_KEY_ID)" 1 \
    "$(grep -cF 'AWS_ACCESS_KEY_ID="$BUCKET_ACCESS_KEY_ID"' "$REC1/docker.argv")"
echo

# ---------------------------------------------------------------------------
echo "T4: aws receives the CONTAINER's credentials, not the host file's"
check "AWS_ACCESS_KEY_ID came from the container" 2 \
    "$(grep -cxF "AWS_ACCESS_KEY_ID=$CONTAINER_KEY_ID" "$REC1/aws.log")"
check "AWS_SECRET_ACCESS_KEY came from the container" 2 \
    "$(grep -cxF "AWS_SECRET_ACCESS_KEY=$CONTAINER_SECRET" "$REC1/aws.log")"
check "region defaults from the container's BUCKET_REGION" 2 \
    "$(grep -cxF "AWS_DEFAULT_REGION=eu-west-2" "$REC1/aws.log")"
check "synced the right site and bucket (private)" 1 \
    "$(grep -cF "ARGS=s3 sync /home/frappe/frappe-bench/sites/$SITE_VALUE/private/files s3://$BUCKET_VALUE/private/files --delete" "$REC1/aws.log")"
check "synced the right site and bucket (public)" 1 \
    "$(grep -cF "ARGS=s3 sync /home/frappe/frappe-bench/sites/$SITE_VALUE/public/files s3://$BUCKET_VALUE/public/files --delete" "$REC1/aws.log")"
echo

# ---------------------------------------------------------------------------
# T5 — anti-vacuity. The pre-fix script must put the key on argv under the same stubs,
#      proving T2 detects the real exposure. A missing ref is a FAILURE, not a skip.
echo "T5: the pre-fix script leaks the key onto argv (anti-vacuity control)"
BASE_SCRIPT="$WORK/pre-fix-sync-files-to-s3.sh"
if git -C "$SCRIPT_DIR" show "$PRE_FIX_REF:scripts/sync-files-to-s3.sh" > "$BASE_SCRIPT" 2>/dev/null; then
    # The pre-fix ENV_FILE was hard-coded; point it at the fixture.
    # shellcheck disable=SC2016
    sed -i.bak 's#^ENV_FILE=.*#ENV_FILE="${ENV_FILE}"#' "$BASE_SCRIPT"
    REC5="$WORK/rec5"
    run_sync "$BASE_SCRIPT" "$REC5" >/dev/null
    if grep -qF -- "$HOST_SECRET" "$REC5/docker.argv"; then
        pass "pre-fix script puts the secret key on docker's argv -- T2 detects the real bug"
    else
        fail "pre-fix script did not reproduce the leak; T2 may not be testing the fix"
    fi
else
    fail "could not read $PRE_FIX_REF:scripts/sync-files-to-s3.sh -- the control did not run (fetch full history)"
fi
echo

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
