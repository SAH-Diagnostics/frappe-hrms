#!/usr/bin/env bash
#
# Tests for the scheduled push of uploaded files to S3 (docker/create-push-cron-job.sh,
# docker/bucket-env.sh, docker/push-to-bucket.sh, and the FILES_BACK_UP_HOURS line of
# generate-env-file.sh).
#
# Why this file exists
# --------------------
# The push never ran in any environment: the S3 copy of uploaded files stopped at the last
# manual push (2026-04-02). Three faults, each enough on its own:
#   1. generate-env-file.sh never wrote FILES_BACK_UP_HOURS, so the container got it empty;
#   2. create-push-cron-job.sh read FILES_BACKUP_HOURS, a name nothing sets;
#   3. it wrote /etc/cron.d without sudo, which the frappe user cannot do.
# Once scheduled, the job would still have failed: cron starts jobs with an empty environment,
# so the push had no bucket credentials and no /usr/local/bin (aws) on PATH.
# Review of the fix (PR #33) added: bucket-env.sh must fail closed rather than fall back to a
# real bucket, every failure must say that files are not backed up, and the log must survive a
# deploy.
#
#   T1-T2   generate-env-file.sh writes FILES_BACK_UP_HOURS, hourly by default
#   T3      docker-compose.yml passes it into the container
#   T4-T7   create-push-cron-job.sh writes exactly the expected cron file, keeps the old name,
#           and refuses values that are not 1-24 hours without failing the boot
#   T8-T9   bucket-env.sh picks up BUCKET_* and SITE_NAME from PID 1's environment under cron,
#           and nothing else
#   T10     the pre-fix script schedules nothing for the same input (the test is not vacuous)
#   T11-T13 a refused sudo or a missing cron installs nothing and says so; the log is ready
#           before the job exists
#   T14     the first push runs in the background, into the log
#   T15     FILES_BACK_UP_HOURS=off disables the push on purpose, first push included
#   T16-T18 bucket-env.sh fails closed without a bucket; odd variable names do not abort it
#   T19-T21 push-to-bucket.sh logs UTC timestamps, refuses to guess a bucket, and runs one
#           push at a time
#   T22-T23 the pre-review scripts fail T11 and T16 (those tests are not vacuous)
#
# `sudo`, `service`, `cron`, `apt-get` and `aws` are stubbed; nothing here touches a server,
# bucket or cron.
#
# Run:  bash docker/__tests__/files-backup-cron.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CRON_SH="$HERE/../create-push-cron-job.sh"
BUCKET_ENV="$HERE/../bucket-env.sh"
PUSH_SH="$HERE/../push-to-bucket.sh"
COMPOSE="$HERE/../docker-compose.yml"
GEN_ENV="$REPO_ROOT/.github/scripts/generate-env-file.sh"
# Last commit with the pre-fix create-push-cron-job.sh (staging, 2026-09-25).
PRE_FIX_REF="e664ca8b98f"
# Last commit before the PR #33 review changes (staging, 2026-09-28).
PRE_REVIEW_REF="bec5cbaf5de278698341a5644de9b7371a9bf507"

passed=0
failed=0
pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
check() { # description, expected, actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# sudo records every call. SUDO_DENY names a command to refuse, the way sudo refuses the frappe
# user; `chown` succeeds without a frappe user in the sandbox.
mkdir -p "$WORK/bin" "$WORK/bin-nocron"
cat > "$WORK/bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${SUDO_LOG:-/dev/null}"
if [ -n "${SUDO_DENY:-}" ] && [ "$1" = "$SUDO_DENY" ]; then
    echo "sudo: a password is required" >&2
    exit 1
fi
[ "$1" = "chown" ] && exit 0
exec "$@"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/service"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/cron"
# The same, less cron, and an apt-get that cannot install it.
cp "$WORK/bin/sudo" "$WORK/bin/service" "$WORK/bin-nocron/"
printf '#!/usr/bin/env bash\necho "E: Unable to locate package cron" >&2\nexit 100\n' > "$WORK/bin-nocron/apt-get"
chmod +x "$WORK/bin/"* "$WORK/bin-nocron/"*

# Stand-ins for push-to-bucket.sh: one slow, one that only leaves a mark.
printf '#!/usr/bin/env bash\nsleep 4\necho "initial push ran"\n' > "$WORK/slow-push.sh"
printf '#!/usr/bin/env bash\ntouch "%s/pushed"\n' "$WORK" > "$WORK/marker-push.sh"
chmod +x "$WORK/slow-push.sh" "$WORK/marker-push.sh"

# Runs a create-push-cron-job.sh in a sandbox; $1 is the script, the rest are VAR=value.
# STUB_BIN selects the stub directory.
run_cron_job() {
    local script="$1"; shift
    rm -f "$WORK/cron.d" "$WORK/push.log" "$WORK/sudo.log" "$WORK/pushed"
    env -i PATH="${STUB_BIN:-$WORK/bin}:/usr/bin:/bin" HOME="$WORK" SUDO_LOG="$WORK/sudo.log" \
        CRON_FILE="$WORK/cron.d" PUSH_LOG="$WORK/push.log" INITIAL_PUSH=0 \
        "$@" bash "$script" 2>&1
}

# Line number of the first sudo call matching an ERE, or "none".
sudo_call_at() { grep -nE "$1" "$WORK/sudo.log" 2>/dev/null | head -1 | cut -d: -f1 | grep . || echo none; }

echo "Testing the S3 files backup schedule"
echo

# ---------------------------------------------------------------------------
echo "generate-env-file.sh"
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "  SKIP: T1-T2 need bash >= 4 (this is ${BASH_VERSION}); on macOS run this file with Homebrew bash"
else
    : > "$WORK/secrets"
    for v in BUCKET_ACCESS_KEY_ID BUCKET_SECRET_ACCESS_KEY BUCKET_ENDPOINT BUCKET_NAME BUCKET_REGION \
        DATABASE_ENDPOINT DATABASE_NAME DATABASE_PASSWORD DATABASE_PORT DATABASE_USERNAME ADMIN_PASSWORD \
        FRAPPE_ENCRYPTION_KEY SITE_NAME SITE_URL EXISTING_SITE UPDATE_CODE; do
        echo "$v=x" >> "$WORK/secrets"
    done
    bash "$GEN_ENV" "$WORK/secrets" "$WORK/env.default" >/dev/null 2>&1
    check "T1 FILES_BACK_UP_HOURS defaults to hourly when the secret lacks it" \
        "FILES_BACK_UP_HOURS=1" "$(grep '^FILES_BACK_UP_HOURS=' "$WORK/env.default")"

    { cat "$WORK/secrets"; echo "FILES_BACK_UP_HOURS=6"; } > "$WORK/secrets.set"
    bash "$GEN_ENV" "$WORK/secrets.set" "$WORK/env.set" >/dev/null 2>&1
    check "T2 FILES_BACK_UP_HOURS from the secret is passed through, once" \
        "FILES_BACK_UP_HOURS=6" "$(grep '^FILES_BACK_UP_HOURS=' "$WORK/env.set")"
fi
echo

# ---------------------------------------------------------------------------
echo "docker-compose.yml"
check "T3 compose passes FILES_BACK_UP_HOURS into the frappe container" 1 \
    "$(tr -d '\r' < "$COMPOSE" | grep -cE '^[[:space:]]+- FILES_BACK_UP_HOURS=\$\{FILES_BACK_UP_HOURS:-\}$')"
echo

# ---------------------------------------------------------------------------
echo "create-push-cron-job.sh"
out="$(run_cron_job "$CRON_SH" FILES_BACK_UP_HOURS=3)"
# The whole file, in order: crontab(5) applies SHELL= and PATH= only to the entries after them.
expected="SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 */3 * * * frappe /home/frappe/push-to-bucket.sh >> $WORK/push.log 2>&1"
check "T4 the cron file is exactly SHELL, PATH (with /usr/local/bin for aws), then the job as frappe" \
    "$expected" "$(cat "$WORK/cron.d" 2>/dev/null)"
check "T4 the cron file ends with a newline (cron ignores an unterminated last line)" \
    "" "$(tail -c 1 "$WORK/cron.d" 2>/dev/null | tr -d '\n')"
check "T4 the push log defaults to the frappe-site-data volume, which survives a deploy" 1 \
    "$(tr -d '\r' < "$CRON_SH" | grep -cxF 'PUSH_LOG="${PUSH_LOG:-/home/frappe/site-data/push-to-bucket.log}"')"
check "T4 compose mounts that volume at /home/frappe/site-data" 1 \
    "$(tr -d '\r' < "$COMPOSE" | grep -cE '^[[:space:]]+- frappe-site-data:/home/frappe/site-data$')"

run_cron_job "$CRON_SH" FILES_BACKUP_HOURS=2 >/dev/null
check "T5 the old FILES_BACKUP_HOURS spelling is still accepted" \
    "0 */2 * * *" "$(grep -oE '^0 \*/[0-9]+ \* \* \*' "$WORK/cron.d" 2>/dev/null)"

run_cron_job "$CRON_SH" FILES_BACK_UP_HOURS=24 >/dev/null
check "T6 24 hours is once a day at midnight" \
    "0 0 * * *" "$(grep -oE '^0 0 \* \* \*' "$WORK/cron.d" 2>/dev/null)"

for bad in "" 0 25 abc; do
    out="$(run_cron_job "$CRON_SH" FILES_BACK_UP_HOURS="$bad")"; rc=$?
    if [ "$rc" -eq 0 ] && [ ! -e "$WORK/cron.d" ] && grep -q 'NOT being backed up' <<<"$out"; then
        pass "T7 '$bad' schedules nothing, warns, and does not fail the boot"
    else
        fail "T7 '$bad' misbehaved (rc=$rc, cron file $( [ -e "$WORK/cron.d" ] && echo written || echo absent))"
    fi
done
echo

# ---------------------------------------------------------------------------
echo "bucket-env.sh"
printf 'BUCKET_NAME=erp-bucket\0BUCKET_ACCESS_KEY_ID=AKIA-test\0SITE_NAME=erp.example\0DB_PASSWORD=db-secret\0' \
    > "$WORK/environ"
got="$(env -i PATH=/usr/bin:/bin PROC_ENVIRON="$WORK/environ" bash -c \
    'source "$1" 2>/dev/null; echo "$S3_BUCKET|$AWS_ACCESS_KEY_ID|$SITE_NAME|${DB_PASSWORD:-unset}"' _ "$BUCKET_ENV")"
check "T8 under cron's empty environment, bucket and site come from PID 1; nothing else does" \
    "erp-bucket|AKIA-test|erp.example|unset" "$got"

got="$(env -i PATH=/usr/bin:/bin BUCKET_NAME=own-bucket PROC_ENVIRON="$WORK/environ" bash -c \
    'source "$1" 2>/dev/null; echo "$S3_BUCKET|${AWS_ACCESS_KEY_ID:-none}"' _ "$BUCKET_ENV")"
check "T9 an environment that already has BUCKET_NAME is left alone" "own-bucket|none" "$got"
echo

# ---------------------------------------------------------------------------
echo "Anti-vacuity"
if git -C "$REPO_ROOT" show "$PRE_FIX_REF:docker/create-push-cron-job.sh" > "$WORK/pre-fix.sh" 2>/dev/null; then
    # The pre-fix script writes the path it hard-codes; point it at the sandbox.
    sed -i.bak "s|/etc/cron.d/frappe-files-backup|$WORK/cron.d|" "$WORK/pre-fix.sh"
    run_cron_job "$WORK/pre-fix.sh" FILES_BACK_UP_HOURS=3 >/dev/null
    check "T10 the pre-fix script schedules nothing for FILES_BACK_UP_HOURS=3" absent \
        "$( [ -e "$WORK/cron.d" ] && echo written || echo absent)"
else
    fail "T10 $PRE_FIX_REF is not in this clone (fetch full history)"
fi
echo

# ---------------------------------------------------------------------------
echo "create-push-cron-job.sh: failures are reported, and nothing is half-installed"
out="$(run_cron_job "$CRON_SH" FILES_BACK_UP_HOURS=3 SUDO_DENY=cp)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$WORK/cron.d" ] && grep -q "could not install $WORK/cron.d" <<<"$out" \
    && grep -q 'NOT being backed up' <<<"$out"; then
    pass "T11 sudo refusing to write the cron file installs nothing, says so, and does not fail the boot"
else
    fail "T11 sudo refused cp: rc=$rc, cron file $( [ -e "$WORK/cron.d" ] && echo written || echo absent), output: $(tr '\n' '|' <<<"$out")"
fi

out="$(run_cron_job "$CRON_SH" FILES_BACK_UP_HOURS=3 SUDO_DENY=touch)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$WORK/cron.d" ] && grep -q 'could not prepare the push log' <<<"$out" \
    && grep -q 'NOT being backed up' <<<"$out"; then
    pass "T12 a push log that cannot be prepared installs no job (a job that cannot open its log never runs)"
else
    fail "T12 sudo refused touch: rc=$rc, cron file $( [ -e "$WORK/cron.d" ] && echo written || echo absent)"
fi

run_cron_job "$CRON_SH" FILES_BACK_UP_HOURS=3 >/dev/null
chown_at="$(sudo_call_at "^chown frappe:frappe $WORK/push.log\$")"
cp_at="$(sudo_call_at "^cp .* $WORK/cron.d\$")"
if [ "$chown_at" != none ] && [ "$cp_at" != none ] && [ "$chown_at" -lt "$cp_at" ]; then
    pass "T12 the log is owned by frappe before the cron file is installed"
else
    fail "T12 order of sudo calls: chown of the log at ${chown_at}, cron file copied at ${cp_at}"
fi

if PATH="$WORK/bin-nocron:/usr/bin:/bin" command -v cron >/dev/null 2>&1; then
    echo "  SKIP: T13 cron is on /usr/bin:/bin on this host, so it cannot be hidden"
else
    out="$(STUB_BIN="$WORK/bin-nocron" run_cron_job "$CRON_SH" FILES_BACK_UP_HOURS=3)"; rc=$?
    if [ "$rc" -eq 0 ] && [ ! -e "$WORK/cron.d" ] && grep -q 'could not be installed' <<<"$out" \
        && grep -q 'NOT being backed up' <<<"$out"; then
        pass "T13 cron missing and apt-get failing installs nothing, says so, and does not fail the boot"
    else
        fail "T13 cron could not be installed: rc=$rc, cron file $( [ -e "$WORK/cron.d" ] && echo written || echo absent)"
    fi
fi
echo

# ---------------------------------------------------------------------------
echo "create-push-cron-job.sh: the first push"
start=$SECONDS
run_cron_job "$CRON_SH" FILES_BACK_UP_HOURS=3 INITIAL_PUSH=1 PUSH_SCRIPT="$WORK/slow-push.sh" >/dev/null
elapsed=$((SECONDS - start))
if [ "$elapsed" -lt 3 ]; then
    pass "T14 the first push runs in the background: the script returned in ${elapsed}s, the push takes 4s"
else
    fail "T14 the script waited ${elapsed}s for the first push; bench would wait for the whole upload"
fi
for _ in $(seq 1 20); do
    grep -q 'initial push ran' "$WORK/push.log" 2>/dev/null && break
    sleep 0.5
done
check "T14 the first push's output goes to the push log" 1 "$(grep -c 'initial push ran' "$WORK/push.log" 2>/dev/null)"
echo

# ---------------------------------------------------------------------------
echo "create-push-cron-job.sh: FILES_BACK_UP_HOURS=off"
out="$(run_cron_job "$CRON_SH" FILES_BACK_UP_HOURS=off INITIAL_PUSH=1 PUSH_SCRIPT="$WORK/marker-push.sh")"; rc=$?
sleep 1
if [ "$rc" -eq 0 ] && [ ! -e "$WORK/cron.d" ] && [ ! -e "$WORK/pushed" ] \
    && grep -q 'disabled on purpose' <<<"$out" && grep -q 'NOT being backed up' <<<"$out"; then
    pass "T15 'off' installs no job, runs no first push, and says the push is disabled on purpose"
else
    fail "T15 off: rc=$rc, cron file $( [ -e "$WORK/cron.d" ] && echo written || echo absent), push $( [ -e "$WORK/pushed" ] && echo ran || echo 'did not run')"
fi
echo

# ---------------------------------------------------------------------------
echo "bucket-env.sh: fails closed"
# Sourced under set -e, as push-to-bucket.sh and fetch-from-bucket.sh do.
source_bucket_env() { # $1 = PROC_ENVIRON; prints S3_BUCKET if sourcing succeeded
    env -i PATH=/usr/bin:/bin PROC_ENVIRON="$1" bash -c \
        'set -e; source "$1"; echo "reached with bucket [$S3_BUCKET]"' _ "$2" 2>&1
}
out="$(source_bucket_env "$WORK/no-such-environ" "$BUCKET_ENV")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'FATAL: BUCKET_NAME is not set' <<<"$out" && ! grep -q 'reached' <<<"$out"; then
    pass "T16 PID 1's environment unreadable: stops with FATAL instead of guessing a bucket"
else
    fail "T16 unreadable environment: rc=$rc, output: $(tr '\n' '|' <<<"$out")"
fi

printf 'BUCKET_NAME=\0SITE_NAME=erp.example\0' > "$WORK/environ-empty-bucket"
out="$(source_bucket_env "$WORK/environ-empty-bucket" "$BUCKET_ENV")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'FATAL' <<<"$out" && ! grep -q 'reached' <<<"$out"; then
    pass "T17 BUCKET_NAME present but empty in PID 1's environment: stops with FATAL"
else
    fail "T17 empty BUCKET_NAME: rc=$rc, output: $(tr '\n' '|' <<<"$out")"
fi

printf 'BUCKET_X.Y=odd\0BUCKET_NAME=erp-bucket\0' > "$WORK/environ-odd-name"
out="$(source_bucket_env "$WORK/environ-odd-name" "$BUCKET_ENV")"; rc=$?
check "T18 a BUCKET_* name that is not a valid identifier is skipped, not fatal" \
    "0|reached with bucket [erp-bucket]" "$rc|$(grep reached <<<"$out")"
echo

# ---------------------------------------------------------------------------
echo "push-to-bucket.sh (the real script, in a sandboxed home)"
mkdir -p "$WORK/home/frappe-bench/sites/erp.example/private/files" "$WORK/awsbin"
cp "$BUCKET_ENV" "$WORK/home/bucket-env.sh"
echo "attachment" > "$WORK/home/frappe-bench/sites/erp.example/private/files/a.txt"
cat > "$WORK/awsbin/aws" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$AWS_LOG"
STUB
chmod +x "$WORK/awsbin/aws"

run_push() { # VAR=value ...
    rm -f "$WORK/aws.log"
    env -i PATH="$WORK/awsbin:/usr/bin:/bin" FRAPPE_HOME="$WORK/home" PUSH_LOCK="$WORK/push.lock" \
        PROC_ENVIRON="$WORK/environ" AWS_LOG="$WORK/aws.log" "$@" bash "$PUSH_SH" 2>&1
}
aws_calls() { if [ -f "$WORK/aws.log" ]; then grep -c . "$WORK/aws.log"; else echo 0; fi; }

out="$(run_push)"; rc=$?
TS='\(20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\)'
check "T19 a push under cron's empty environment syncs private, public and logs to the right bucket" \
    "0|3|3" "$rc|$(aws_calls)|$(grep -c ' s3://erp-bucket/' "$WORK/aws.log" 2>/dev/null)"
check "T19 the start and end lines carry UTC timestamps" "1|1" \
    "$(grep -cE "^=== Pushing site files to S3 $TS ===\$" <<<"$out")|$(grep -cE "^=== Push to bucket completed $TS ===\$" <<<"$out")"

out="$(run_push PROC_ENVIRON="$WORK/no-such-environ")"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(aws_calls)" = 0 ] && [ ! -e "$WORK/home/frappe-bench/sites/hrms.localhost" ] \
    && grep -q FATAL <<<"$out" && ! grep -q 'Push to bucket completed' <<<"$out"; then
    pass "T20 without the bucket settings the push fails: no sync, no phantom site directory, no 'completed'"
else
    fail "T20 push without settings: rc=$rc, aws calls $(aws_calls), output: $(tr '\n' '|' <<<"$out")"
fi

if ! command -v flock >/dev/null 2>&1; then
    echo "  SKIP: T21 needs flock (util-linux), which this host lacks"
else
    flock "$WORK/push.lock" sleep 5 &
    holder=$!
    for _ in $(seq 1 20); do flock -n "$WORK/push.lock" true 2>/dev/null || break; sleep 0.1; done
    out="$(run_push)"; rc=$?
    check "T21 a push while another holds the lock skips, says so, and syncs nothing" \
        "0|1|0" "$rc|$(grep -c 'Another push is still running' <<<"$out")|$(aws_calls)"
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
fi
echo

# ---------------------------------------------------------------------------
echo "Anti-vacuity (pre-review scripts)"
if git -C "$REPO_ROOT" show "$PRE_REVIEW_REF:docker/create-push-cron-job.sh" > "$WORK/pre-review-cron.sh" 2>/dev/null \
    && git -C "$REPO_ROOT" show "$PRE_REVIEW_REF:docker/bucket-env.sh" > "$WORK/pre-review-bucket-env.sh" 2>/dev/null; then
    out="$(run_cron_job "$WORK/pre-review-cron.sh" FILES_BACK_UP_HOURS=3 SUDO_DENY=cp)"; rc=$?
    if [ "$rc" -ne 0 ] && ! grep -q 'NOT being backed up' <<<"$out"; then
        pass "T22 the pre-review script dies silently when sudo refuses cp -- T11 detects that"
    else
        fail "T22 the pre-review script did not reproduce the silent failure (rc=$rc); T11 may be vacuous"
    fi
    out="$(source_bucket_env "$WORK/no-such-environ" "$WORK/pre-review-bucket-env.sh")"
    check "T23 the pre-review bucket-env.sh guesses dev-erp-storage -- T16 detects that" \
        "reached with bucket [dev-erp-storage]" "$(grep reached <<<"$out")"
else
    fail "T22-T23 $PRE_REVIEW_REF is not in this clone (fetch full history)"
fi
echo

echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
