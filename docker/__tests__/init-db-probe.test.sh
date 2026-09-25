#!/usr/bin/env bash
#
# Tests for the Frappe-site detection probe in docker/init.sh.
#
# Ticket: VC-620 — ERP production outage, Frappe container crashed with no restart policy.
#
# Why this file exists
# --------------------
# docker/init.sh decides whether to run `bench new-site` based on whether it can find a
# Frappe schema in the target database. Getting that decision wrong in the "no site"
# direction creates a new site over live production data.
#
# Two earlier shapes of this code were wrong in ways that looked right:
#
#   * The original swallowed mysql's stderr and tested only whether "tabUser" appeared in
#     stdout, so "cannot connect" and "database is empty" were identical.
#   * The first fix added a separate `SELECT 1` reachability pre-flight, then still ran the
#     real query through `... | grep -q`. With no `set -o pipefail` the pipeline reports
#     grep's status, so the real query's failure stayed invisible and a connection flap
#     between the two calls still fell through to `bench new-site`.
#
# The probe must fail CLOSED on a fault, and must still permit genuine first-time
# provisioning — including when the database does not exist yet.
#
# Scenarios run the extracted function against a stubbed `mysql`; the caller scenarios run
# the real decision block from init.sh with `mysql` and `bench` both stubbed, so a mutation
# that makes the caller swallow the guard is caught too. Nothing here touches a database.
#
# Run:  bash docker/__tests__/init-db-probe.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SH="${INIT_SH:-$SCRIPT_DIR/../init.sh}"

if [ ! -f "$INIT_SH" ]; then
    echo "FATAL: cannot find init.sh at $INIT_SH" >&2
    exit 1
fi

PASS=0
FAIL=0

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# The function is declared at column zero and closed by a `}` at column zero, so this stays
# correct if its line numbers move.
extract_function() {
    sed -n '/^database_has_frappe_site() {/,/^}/p' "${1:-$INIT_SH}"
}

# Run one scenario in a subshell so an `exit` inside the guard is contained.
# $1 = the body of the `mysql` stub.
run_scenario() {
    local mysql_stub="$1"
    local fn_source
    fn_source="$(extract_function)"

    # SC2034: these are consumed by the function eval'd in below, which shellcheck cannot
    # see through. The directive scopes to the whole subshell.
    # shellcheck disable=SC2034
    (
        set +e
        DB_HOST_VALUE="db.example.invalid"
        DB_PORT_VALUE="3306"
        DB_USER_VALUE="tester"
        DB_PASSWORD_VALUE="unused-by-the-stub"
        DB_NAME_VALUE="erp_test"

        eval "$mysql_stub"
        eval "$fn_source"

        database_has_frappe_site
        echo "RESULT_CODE=$?"
    ) 2>&1
}

echo "Testing the Frappe-site detection probe in: $INIT_SH"
echo

# ---------------------------------------------------------------------------
# T1 — unreachable database must ABORT, not report "no site".
# ---------------------------------------------------------------------------
echo "T1: unreachable database aborts (fails closed)"
T1_OUT="$(run_scenario '
mysql() { echo "ERROR 1040 (HY000): Too many connections" >&2; return 1; }
')"

if grep -q "RESULT_CODE=" <<<"$T1_OUT"; then
    bad "continued past an unreachable database instead of aborting"
else
    ok "aborted before returning a verdict"
fi
if grep -q "FATAL: cannot determine the state" <<<"$T1_OUT"; then
    ok "emitted a FATAL diagnostic"
else
    bad "no FATAL diagnostic emitted"
fi
if grep -q "Too many connections" <<<"$T1_OUT"; then
    ok "surfaced the underlying mysql error"
else
    bad "mysql's stderr was discarded"
fi

# ---------------------------------------------------------------------------
# T2 — reachable, schema present -> "has site" (0)
# ---------------------------------------------------------------------------
echo
echo "T2: existing schema reports 'has site'"
T2_OUT="$(run_scenario '
mysql() { echo "Tables_in_erp_test (tabUser)"; echo "tabUser"; return 0; }
')"
if grep -q "RESULT_CODE=0" <<<"$T2_OUT"; then
    ok "returned 0 (site exists)"
else
    bad "expected 0, got: $(tr '\n' ' ' <<<"$T2_OUT")"
fi

# ---------------------------------------------------------------------------
# T3 — reachable, database exists but empty -> "no site" (1)
# ---------------------------------------------------------------------------
echo
echo "T3: existing but empty database reports 'no site'"
T3_OUT="$(run_scenario '
mysql() { return 0; }   # connects, database exists, no rows
')"
if grep -q "RESULT_CODE=1" <<<"$T3_OUT"; then
    ok "returned 1 — provisioning into an empty database still works"
else
    bad "expected 1, got: $(tr '\n' ' ' <<<"$T3_OUT")"
fi

# ---------------------------------------------------------------------------
# T4 — database does not exist yet (ERROR 1049) -> "no site" (1), NOT fatal.
#      Regression for the second wrong fix, which aborted first-time provisioning
#      and, under `restart: unless-stopped`, crash-looped a new environment forever.
# ---------------------------------------------------------------------------
echo
echo "T4: nonexistent database is a first-run state, not a fault"
T4_OUT="$(run_scenario '
mysql() { echo "ERROR 1049 (42000): Unknown database '"'"'erp_test'"'"'" >&2; return 1; }
')"
if grep -q "RESULT_CODE=1" <<<"$T4_OUT"; then
    ok "returned 1 — first-time provisioning is not blocked"
else
    bad "ERROR 1049 was treated as fatal; a fresh environment cannot provision. Got: $(tr '\n' ' ' <<<"$T4_OUT")"
fi

# ---------------------------------------------------------------------------
# T5 — the flap. A probe that checks reachability separately from the real query
#      passes T1 and still fails open here. This is the scenario the second fix missed.
# ---------------------------------------------------------------------------
echo
echo "T5: connectivity succeeds, then the real query fails (pool flap)"
# SC2016: the single quotes are deliberate -- "$@" inside the stub must stay literal so it
# expands when the stub is eval'd, not when this string is built.
# shellcheck disable=SC2016
T5_OUT="$(run_scenario '
mysql() {
    for a in "$@"; do
        case "$a" in
            *"SELECT 1"*)   echo "1"; return 0 ;;
            *"SHOW TABLES"*) echo "ERROR 1040 (HY000): Too many connections" >&2; return 1 ;;
        esac
    done
    return 0
}
')"
if grep -q "RESULT_CODE=" <<<"$T5_OUT"; then
    bad "a flap between reachability and the real query still reports a verdict — FAILS OPEN"
else
    ok "aborted — the decision is made by the same call that failed"
fi

# ---------------------------------------------------------------------------
# T6 — drive the REAL caller block, not just the function. A mutation that makes
#      the caller swallow the guard's `exit` must be caught here.
# ---------------------------------------------------------------------------
echo
echo "T6: the real caller never reaches 'bench new-site' on a fault"
# Build the harness OUTSIDE a command substitution: bash 3.2 (the macOS default)
# mis-parses a heredoc nested inside `$( )`.
T6_DIR="$(mktemp -d)"
trap 'rm -rf "$T6_DIR"' EXIT

# The function, plus ONLY the caller's decision block. Intermediate `fi`s are indented,
# so the first column-zero `fi` closes the block.
extract_function > "$T6_DIR/caller.sh"
awk '/^if \[ -n "\$DB_HOST_VALUE" \] && \[ -n "\$DB_NAME_VALUE" \]; then/{f=1}
     f{print}
     f && /^fi$/{exit}' "$INIT_SH" >> "$T6_DIR/caller.sh"

cat > "$T6_DIR/harness.sh" <<'HEOF'
set -e
DB_HOST_VALUE="db.example.invalid"; DB_PORT_VALUE="3306"; DB_USER_VALUE="t"
DB_PASSWORD_VALUE="p"; DB_NAME_VALUE="erp_test"; SITE_NAME="erp.local"
mysql() { echo "ERROR 1040 (HY000): Too many connections" >&2; return 1; }
bench() {
    case "$*" in
        *new-site*) echo "!!! BENCH NEW-SITE INVOKED !!!" ;;
        *) return 1 ;;
    esac
}
. "$(dirname "$0")/caller.sh"
HEOF

if ! grep -q "new-site" "$T6_DIR/caller.sh"; then
    bad "T6 extraction produced no 'bench new-site' call — the harness is not exercising the real branch"
fi

T6_OUT="$(bash "$T6_DIR/harness.sh" 2>&1; echo "CALLER_EXIT=$?")"

if grep -q "BENCH NEW-SITE INVOKED" <<<"$T6_OUT"; then
    bad "the real caller ran 'bench new-site' against an unreachable database"
else
    ok "'bench new-site' was never invoked"
fi
if grep -q "FATAL" <<<"$T6_OUT"; then
    ok "caller surfaced the FATAL"
else
    bad "caller swallowed the FATAL"
fi

# ---------------------------------------------------------------------------
# T7 — anti-vacuity. The pre-fix version must FAIL T1's scenario, proving these
#      tests detect the real bug rather than merely passing.
#      A missing ref is a HARD FAILURE, not a skip: a shallow CI checkout would
#      otherwise silently drop the only control on the whole suite.
# ---------------------------------------------------------------------------
echo
echo "T7: the pre-fix version behaves differently (anti-vacuity control)"
# Pinned, not origin/main: once staging is promoted, main carries the fix and a moving ref
# would turn this control red. 4c09caf84 is the last main commit before the VC-620 probe.
PRE_FIX_REF="4c09caf847c95ca0e5de352330ad5bc9314295ae"
BASE_INIT="$(mktemp)"
trap 'rm -f "$BASE_INIT"' EXIT

if git -C "$SCRIPT_DIR" show "$PRE_FIX_REF:docker/init.sh" > "$BASE_INIT" 2>/dev/null; then
    T7_OUT="$(INIT_SH="$BASE_INIT" run_scenario '
mysql() { echo "ERROR 1040 (HY000): Too many connections" >&2; return 1; }
')"
    if grep -q "RESULT_CODE=1" <<<"$T7_OUT"; then
        ok "pre-fix version returns 1 ('no site') on an unreachable DB — the bug is real and T1 detects it"
    else
        bad "pre-fix version did not reproduce the bug; T1 may not be testing the fix. Got: $(tr '\n' ' ' <<<"$T7_OUT")"
    fi
else
    bad "could not read $PRE_FIX_REF:docker/init.sh — the anti-vacuity control did not run. Fetch the base ref (a shallow clone is not sufficient)."
fi

# ---------------------------------------------------------------------------
# T8/T9 — EXISTING_SITE, the second guard.
#
# The probe answers "is there a schema?" by inference. EXISTING_SITE answers "should there
# be one?" by declaration. They fail independently: the probe catches a database that
# cannot be reached, EXISTING_SITE catches one that is reached and answers wrongly -- a
# DB_NAME typo, an instance restored empty, a replica pointed at by mistake. In all of
# those the probe honestly reports "no schema" and would authorise creation on its own.
#
# Both scenarios therefore use a REACHABLE, genuinely EMPTY database, which is precisely
# the case the probe is designed to let through.

GUARD_DIR="$(mktemp -d)"

{
    extract_function
    sed -n '/^assert_provisioning_allowed() {/,/^}/p' "$INIT_SH"
    awk '/^if \[ -n "\$DB_HOST_VALUE" \] && \[ -n "\$DB_NAME_VALUE" \]; then/{f=1}
         f{print}
         f && /^fi$/{exit}' "$INIT_SH"
} > "$GUARD_DIR/caller.sh"

cat > "$GUARD_DIR/harness.sh" <<'HEOF'
set +e
DB_HOST_VALUE="db.example.invalid"
DB_PORT_VALUE="3306"
DB_USER_VALUE="tester"
DB_PASSWORD_VALUE="unused-by-the-stub"
DB_NAME_VALUE="erp_test"
ADMIN_PASSWORD_VALUE="unused-by-the-stub"
SITE_NAME="erp.example"
EXISTING_SITE_VALUE="$EXISTING_SITE_UNDER_TEST"

# Reachable and empty: the probe truthfully reports "no schema".
mysql() { return 0; }

# Stop the harness the moment provisioning is reached, so nothing touches the filesystem.
bench() {
    case "$1" in
        new-site) echo "BENCH NEW-SITE INVOKED"; exit 0 ;;
        *) return 1 ;;
    esac
}

. "$GUARD_CALLER"
HEOF

if ! grep -q "assert_provisioning_allowed" "$GUARD_DIR/caller.sh"; then
    bad "T8/T9 extraction found no 'assert_provisioning_allowed' call — the harness is not exercising the guard"
fi

echo
echo "T8: EXISTING_SITE=true blocks provisioning into a reachable, empty database"
T8_OUT="$(EXISTING_SITE_UNDER_TEST=true GUARD_CALLER="$GUARD_DIR/caller.sh" \
    bash "$GUARD_DIR/harness.sh" 2>&1; echo "CALLER_EXIT=$?")"

if grep -q "BENCH NEW-SITE INVOKED" <<<"$T8_OUT"; then
    bad "provisioning ran although the environment declares a site already exists"
else
    ok "'bench new-site' was never invoked"
fi

if grep -q "FATAL" <<<"$T8_OUT"; then
    ok "emitted a FATAL diagnostic"
else
    bad "aborted without explaining why"
fi

if grep -q "CALLER_EXIT=1" <<<"$T8_OUT"; then
    ok "exited non-zero, so the container does not come up pretending to be healthy"
else
    bad "did not exit 1. Got: $(tr '\n' ' ' <<<"$T8_OUT")"
fi

echo
echo "T9: EXISTING_SITE=false still permits genuine first-time provisioning"
T9_OUT="$(EXISTING_SITE_UNDER_TEST=false GUARD_CALLER="$GUARD_DIR/caller.sh" \
    bash "$GUARD_DIR/harness.sh" 2>&1; echo "CALLER_EXIT=$?")"

if grep -q "BENCH NEW-SITE INVOKED" <<<"$T9_OUT"; then
    ok "provisioning proceeded — the guard does not block a legitimate new environment"
else
    bad "the guard blocked first-time provisioning. Got: $(tr '\n' ' ' <<<"$T9_OUT")"
fi

rm -rf "$GUARD_DIR"

# ---------------------------------------------------------------------------
# T10 — the DB password never reaches mysql's argv (VC-657).
#
# An argv password is readable by every user on the host through `ps` and
# /proc/<pid>/cmdline for as long as the client runs. The probe must hand it over in
# MYSQL_PWD instead. The stub is a real executable on PATH, not a shell function, so the
# assertion also proves MYSQL_PWD is EXPORTED into the child's environment -- which is
# what the real mysql client reads.
# ---------------------------------------------------------------------------
echo
echo "T10: the probe passes the password in MYSQL_PWD, never on argv"
PWD_DIR="$(mktemp -d)"
T10_PASSWORD="probe-pw-7f3c-not-a-real-secret"
cat > "$PWD_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$0" "$@" > "$STUB_RECORD_DIR/argv"
printf '%s' "${MYSQL_PWD-<unset>}" > "$STUB_RECORD_DIR/mysql_pwd"
echo "tabUser"
exit 0
STUB
chmod +x "$PWD_DIR/mysql"

# The stub runs as a child process, so it needs STUB_RECORD_DIR exported; run_scenario's
# subshell sees the plain shell variables (PWD_DIR, T10_PASSWORD) directly.
# shellcheck disable=SC2034
STUB_RECORD_DIR="$PWD_DIR"
# SC2016: the stub string is eval'd inside run_scenario, so its $VARs must stay literal here.
# shellcheck disable=SC2016
T10_OUT="$(run_scenario '
export STUB_RECORD_DIR
PATH="$PWD_DIR:$PATH"
DB_PASSWORD_VALUE="$T10_PASSWORD"
')"

if [ -f "$PWD_DIR/argv" ]; then
    ok "the probe invoked the mysql client (non-vacuous)"
else
    bad "the stub mysql was never called; T10 did not exercise the probe. Got: $(tr '\n' ' ' <<<"$T10_OUT")"
fi
if grep -q "RESULT_CODE=0" <<<"$T10_OUT"; then
    ok "the probe still reads the stub's answer (tabUser -> has site)"
else
    bad "expected RESULT_CODE=0, got: $(tr '\n' ' ' <<<"$T10_OUT")"
fi
if [ -f "$PWD_DIR/argv" ] && ! grep -qF -- "$T10_PASSWORD" "$PWD_DIR/argv"; then
    ok "the password is not in mysql's argv"
else
    bad "the password appears in mysql's argv (visible to ps / /proc/<pid>/cmdline)"
fi
if [ "$(cat "$PWD_DIR/mysql_pwd" 2>/dev/null)" = "$T10_PASSWORD" ]; then
    ok "MYSQL_PWD carries the password into the client's environment"
else
    bad "MYSQL_PWD was '$(cat "$PWD_DIR/mysql_pwd" 2>/dev/null)', expected the DB password"
fi
rm -rf "$PWD_DIR"

# Static checks over the whole file: they cover the fallback CREATE DATABASE call, which
# only runs after a failed `bench new-site` and so cannot be reached without a filesystem.
echo
echo "T11: no mysql call in init.sh puts the password on argv, and bench runs without --verbose"
# SC2016: the patterns below are literal source text, not expansions.
# shellcheck disable=SC2016
if grep -qF -- '-p"$DB_PASSWORD_VALUE"' "$INIT_SH"; then
    bad "init.sh still passes -p\"\$DB_PASSWORD_VALUE\" on a mysql command line"
else
    ok "no -p\"\$DB_PASSWORD_VALUE\" in init.sh"
fi
MYSQL_CALLS="$(grep -cE '(^|[[:space:]]|\()mysql -h ' "$INIT_SH")"
# shellcheck disable=SC2016
MYSQL_PWD_CALLS="$(grep -cE 'MYSQL_PWD="\$DB_PASSWORD_VALUE" mysql -h ' "$INIT_SH")"
if [ "$MYSQL_CALLS" -ge 2 ] && [ "$MYSQL_CALLS" = "$MYSQL_PWD_CALLS" ]; then
    ok "all $MYSQL_CALLS mysql client calls take the password from MYSQL_PWD"
else
    bad "expected every mysql call (>= 2) to be prefixed by MYSQL_PWD; calls=$MYSQL_CALLS, with MYSQL_PWD=$MYSQL_PWD_CALLS"
fi
# --verbose makes bench echo its database commands, and the new-site call carries the DB
# root and admin passwords.
if grep -qE '^[[:space:]]*--verbose' "$INIT_SH"; then
    bad "init.sh still passes --verbose to bench"
else
    ok "no --verbose flag in init.sh"
fi

echo
echo "-----------------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
