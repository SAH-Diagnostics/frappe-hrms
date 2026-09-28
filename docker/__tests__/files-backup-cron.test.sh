#!/usr/bin/env bash
#
# Tests for the scheduled push of uploaded files to S3 (docker/create-push-cron-job.sh,
# docker/bucket-env.sh, and the FILES_BACK_UP_HOURS line of generate-env-file.sh).
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
#
#   T1-T2  generate-env-file.sh writes FILES_BACK_UP_HOURS, hourly by default
#   T3     docker-compose.yml passes it into the container
#   T4-T7  create-push-cron-job.sh schedules from the compose name, keeps the old name, and
#          refuses values that are not 1-24 hours without failing the boot
#   T8-T9  bucket-env.sh picks up BUCKET_* and SITE_NAME from PID 1's environment under cron,
#          and nothing else
#   T10    the pre-fix script schedules nothing for the same input (the test is not vacuous)
#
# `sudo`, `service` and `cron` are stubbed; nothing here touches a server, bucket or cron.
#
# Run:  bash docker/__tests__/files-backup-cron.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CRON_SH="$HERE/../create-push-cron-job.sh"
BUCKET_ENV="$HERE/../bucket-env.sh"
COMPOSE="$HERE/../docker-compose.yml"
GEN_ENV="$REPO_ROOT/.github/scripts/generate-env-file.sh"
# Last commit with the pre-fix create-push-cron-job.sh (staging, 2026-09-25).
PRE_FIX_REF="e664ca8b98f"

passed=0
failed=0
pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
check() { # description, expected, actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/service"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/cron"
chmod +x "$WORK/bin/"*

# Runs a create-push-cron-job.sh in a sandbox; $1 is the script, the rest are VAR=value.
run_cron_job() {
    local script="$1"; shift
    rm -f "$WORK/cron.d" "$WORK/push.log"
    env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK" \
        CRON_FILE="$WORK/cron.d" PUSH_LOG="$WORK/push.log" INITIAL_PUSH=0 \
        "$@" bash "$script" 2>&1
}

echo "Testing the S3 files backup schedule"
echo

# ---------------------------------------------------------------------------
echo "generate-env-file.sh"
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "  SKIP: T1-T2 need bash >= 4 (this is ${BASH_VERSION})"
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
check "T4 schedules the push as frappe every 3 hours, logging to the push log" \
    "0 */3 * * * frappe /home/frappe/push-to-bucket.sh >> $WORK/push.log 2>&1" \
    "$(grep -E '^[0-9*]' "$WORK/cron.d" 2>/dev/null)"
check "T4 the cron file puts /usr/local/bin (aws) on PATH" 1 \
    "$(grep -cE '^PATH=.*/usr/local/bin' "$WORK/cron.d" 2>/dev/null)"
check "T4 the cron file runs jobs under bash" 1 "$(grep -cx 'SHELL=/bin/bash' "$WORK/cron.d" 2>/dev/null)"

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

echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
