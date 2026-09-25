#!/usr/bin/env bash
#
# Tests for how the two-factor authentication policy (docker/configure_2fa.py, VC-644) is wired
# into the container boot and the deploy's .env generation.
#
#   T1-T3  init.sh runs the policy with the bench's interpreter, from the sites directory, after the
#          apps are installed and before the cache is cleared.
#   T4     a failing policy run does NOT abort init.sh under `set -e` (the ERP must still start).
#   T5     a successful policy run is reported and init.sh carries on.
#   T6-T8  generate-env-file.sh passes the optional FRAPPE_2FA_* knobs through when the secret has
#          them, omits them when it does not, and still refuses a secret missing a required var.
#   T9     docker-compose.yml supplies the secure defaults.
#   T10    a secrets file shaped like fetch-aws-secrets.sh output survives the deploy's `source` only
#          when a value containing a space is stored with literal quotes (the documented rule).
#
# Run:  bash docker/__tests__/init-2fa-policy.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SH="$HERE/../init.sh"
COMPOSE="$HERE/../docker-compose.yml"
GEN_ENV="$HERE/../../.github/scripts/generate-env-file.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

line_of() { grep -n -F -- "$1" "$INIT_SH" | head -1 | cut -d: -f1; }

echo "init.sh wiring"
call=$(grep -n '^apply_two_factor_policy$' "$INIT_SH" | cut -d: -f1)
crm=$(line_of 'install-app sah_crm')
clear=$(line_of 'clear-cache')

if [ -n "$call" ]; then ok "T1 init.sh calls apply_two_factor_policy"; else bad "T1 init.sh never calls apply_two_factor_policy"; fi
if [ -n "$call" ] && [ -n "$crm" ] && [ -n "$clear" ] && [ "$crm" -lt "$call" ] && [ "$call" -lt "$clear" ]; then
    ok "T2 policy runs after sah_crm install ($crm) and before clear-cache ($clear)"
else
    bad "T2 policy call ($call) is not between sah_crm install ($crm) and clear-cache ($clear)"
fi
if grep -q 'cd "$BENCH_DIR/sites" && "$BENCH_DIR/env/bin/python" "$TWO_FACTOR_POLICY_SCRIPT" "$SITE_NAME"' "$INIT_SH"; then
    ok "T3 policy runs with the bench env python from sites/"
else
    bad "T3 policy is not run with the bench env python from sites/"
fi

# Extract the function exactly as written and run it under set -e with a stubbed bench.
sed -n '/^apply_two_factor_policy() {/,/^}/p' "$INIT_SH" > "$TMP/hook.sh"
mkdir -p "$TMP/bench/sites" "$TMP/bench/env/bin"

run_hook() {
    cat > "$TMP/bench/env/bin/python" <<EOF
#!/usr/bin/env bash
echo "stub python cwd=\$(basename "\$PWD") args=\$*"
exit $1
EOF
    chmod +x "$TMP/bench/env/bin/python"
    bash -c "set -e
        BENCH_DIR='$TMP/bench'; SITE_NAME='erp.example'; TWO_FACTOR_POLICY_SCRIPT='/workspace/configure_2fa.py'
        source '$TMP/hook.sh'
        apply_two_factor_policy
        echo AFTER_HOOK" 2>&1
}

out=$(run_hook 1); rc=$?
if [ $rc -eq 0 ] && grep -q AFTER_HOOK <<<"$out" && grep -q "2FA policy NOT applied" <<<"$out"; then
    ok "T4 failing policy is reported and boot continues under set -e"
else
    bad "T4 failing policy aborted boot or was silent (rc=$rc): $out"
fi

out=$(run_hook 0); rc=$?
if [ $rc -eq 0 ] && grep -q AFTER_HOOK <<<"$out" && ! grep -q "NOT applied" <<<"$out" \
    && grep -q "cwd=sites args=/workspace/configure_2fa.py erp.example" <<<"$out"; then
    ok "T5 successful policy run passes the site and continues"
else
    bad "T5 successful policy run misbehaved (rc=$rc): $out"
fi

echo "generate-env-file.sh"
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    # The deploy runs this on ubuntu runners; `declare -A` needs bash 4+. Local macOS ships 3.2:
    #   docker run --rm -v "$PWD":/w -w /w bash:5 bash docker/__tests__/init-2fa-policy.test.sh
    echo "  SKIP: T6-T8, T11 need bash >= 4 (this is ${BASH_VERSION}) — run in bash:5, see comment"
else
REQUIRED=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION BUCKET_ACCESS_KEY_ID BUCKET_SECRET_ACCESS_KEY
    BUCKET_ENDPOINT BUCKET_NAME BUCKET_REGION DATABASE_ENDPOINT DATABASE_NAME DATABASE_PASSWORD DATABASE_PORT
    DATABASE_USERNAME ADMIN_PASSWORD FRAPPE_ENCRYPTION_KEY SITE_NAME SITE_URL EXISTING_SITE UPDATE_CODE)
: > "$TMP/secrets"
for v in "${REQUIRED[@]}"; do echo "$v=x" >> "$TMP/secrets"; done

bash "$GEN_ENV" "$TMP/secrets" "$TMP/env.without" >/dev/null 2>&1
if grep -qx 'SITE_URL=x' "$TMP/env.without" 2>/dev/null && ! grep -q '^FRAPPE_2FA_' "$TMP/env.without"; then
    ok "T6 optional 2FA vars are omitted when the secret lacks them"
else
    bad "T6 generate-env-file failed or wrote 2FA vars that were not in the secret"
fi

cp "$TMP/secrets" "$TMP/secrets.with"
printf 'FRAPPE_2FA_ROLES=2FA-Pilot\nFRAPPE_2FA_ISSUER="SAH ERP"\n' >> "$TMP/secrets.with"
bash "$GEN_ENV" "$TMP/secrets.with" "$TMP/env.with" >/dev/null 2>&1
if grep -qx 'FRAPPE_2FA_ROLES=2FA-Pilot' "$TMP/env.with" && grep -qx 'FRAPPE_2FA_ISSUER=SAH ERP' "$TMP/env.with" \
    && ! grep -q '^FRAPPE_2FA_ENABLED' "$TMP/env.with"; then
    ok "T7 optional 2FA vars present in the secret are passed through"
else
    bad "T7 optional 2FA vars were not passed through: $(grep FRAPPE_2FA "$TMP/env.with" 2>/dev/null)"
fi

# A Fernet key ends in one '=' with no other '='; bash 5 `IFS='=' read` drops exactly that one, so the
# key reached the box truncated and init.sh refused to boot (staging, 2026-09-25).
grep -vE '^(FRAPPE_ENCRYPTION_KEY|ADMIN_PASSWORD)=' "$TMP/secrets" > "$TMP/secrets.pad"
printf 'FRAPPE_ENCRYPTION_KEY=pad-test=\nADMIN_PASSWORD=a=b=\n' >> "$TMP/secrets.pad"
bash "$GEN_ENV" "$TMP/secrets.pad" "$TMP/env.pad" >/dev/null 2>&1
if grep -qx 'FRAPPE_ENCRYPTION_KEY=pad-test=' "$TMP/env.pad" && grep -qx 'ADMIN_PASSWORD=a=b=' "$TMP/env.pad"; then
    ok "T11 values keep every '=' after the first, including trailing padding"
else
    bad "T11 '=' in a value was lost: $(grep -E '^(FRAPPE_ENCRYPTION_KEY|ADMIN_PASSWORD)=' "$TMP/env.pad" 2>/dev/null)"
fi

grep -v '^SITE_URL=' "$TMP/secrets.with" > "$TMP/secrets.broken"
if bash "$GEN_ENV" "$TMP/secrets.broken" "$TMP/env.broken" >/dev/null 2>&1; then
    bad "T8 a secret missing a required var was accepted"
else
    ok "T8 a missing required var still fails the deploy"
fi
fi

echo "secrets.env sourcing"
printf 'FRAPPE_2FA_ROLES="System Manager"\nFRAPPE_2FA_ISSUER="SAH ERP"\n' > "$TMP/secrets.quoted"
printf 'FRAPPE_2FA_ROLES=System Manager\n' > "$TMP/secrets.unquoted"
if bash -e -c "source '$TMP/secrets.quoted' && [ \"\$FRAPPE_2FA_ROLES\" = 'System Manager' ]" >/dev/null 2>&1 \
    && ! bash -e -c "source '$TMP/secrets.unquoted'" >/dev/null 2>&1; then
    ok "T10 a spaced value survives source only when stored quoted"
else
    bad "T10 quoting rule for spaced secret values does not hold"
fi

echo "docker-compose.yml"
if grep -qF 'FRAPPE_2FA_ENABLED=${FRAPPE_2FA_ENABLED:-1}' "$COMPOSE" \
    && grep -qF 'FRAPPE_2FA_ROLES=${FRAPPE_2FA_ROLES:-All}' "$COMPOSE" \
    && grep -qF 'FRAPPE_2FA_ISSUER=${FRAPPE_2FA_ISSUER:-SAH ERP}' "$COMPOSE"; then
    ok "T9 compose defaults enforce OTP-app 2FA for all users"
else
    bad "T9 compose does not pass the secure 2FA defaults"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
