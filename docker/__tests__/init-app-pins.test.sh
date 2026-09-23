#!/usr/bin/env bash
#
# Tests for the pinned application versions in docker/init.sh
#
# Why this file exists
# --------------------
# `sites/` is not a Docker volume, so `compose down && up` rebuilds the bench from scratch and
# re-clones frappe, erpnext, hrms and sah_crm on every deploy -- and on every container restart,
# now that a restart policy exists. While those clones tracked the `version-16` *branch*, each
# rebuild installed whatever was newest that day.
#
# That is measured, not assumed. Production was built 2026-07-29 and staging 2026-09-23 from the
# same branch names and ended up 719 (frappe), 639 (erpnext) and 204 (hrms) commits apart. An
# unpinned production rebuild would therefore have shipped ~1,562 commits of upstream change to
# an HR and payroll system as a side effect of a deploy-pipeline fix.
#
# These tests pin that down literally: no upstream app may be cloned from a moving ref, and the
# pinned values must be the ones production is running. sah_crm is exempt by design -- it is our
# own app and tracking its branch is the point.
#
# Run:  bash docker/__tests__/init-app-pins.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

INIT_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/init.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$INIT_SH" ]; then
    echo "FATAL: cannot find init.sh at $INIT_SH" >&2
    exit 1
fi

echo "Testing application version pinning: $INIT_SH"
echo

# ---------------------------------------------------------------------------
echo "T1: no upstream app is cloned from a moving branch"
# `version-16` is the ref this change exists to remove. Catching it anywhere in a clone
# argument is the single most valuable assertion here, because reintroducing it silently
# restores the original bug.
moving="$(grep -nE '(--branch|--frappe-branch)[[:space:]]+"?version-1[0-9]' "$INIT_SH" || true)"
if [ -z "$moving" ]; then
    ok "no 'version-NN' branch ref remains in a clone argument"
else
    bad "a moving branch ref is still used:"
    while IFS= read -r line; do printf '        %s\n' "$line"; done <<<"$moving"
fi
echo

# ---------------------------------------------------------------------------
echo "T2: the pins are the versions production is running"
# Tags, not SHAs: `bench init --frappe-branch` and `bench get-app --branch` forward to
# `git clone --branch`, which takes a branch or tag but not an arbitrary commit.
check_pin() { # var, expected
    local actual
    actual="$(grep -E "^$1=" "$INIT_SH" | sed -E 's/.*:-([^}]*)\}.*/\1/')"
    if [ "$actual" = "$2" ]; then
        ok "$1 is pinned to $2"
    else
        bad "$1 is '$actual', expected '$2'"
    fi
}
check_pin FRAPPE_REF  v16.29.0
check_pin ERPNEXT_REF v16.30.0
check_pin HRMS_REF    v16.15.0
echo

# ---------------------------------------------------------------------------
echo "T3: every upstream clone actually uses the pinned variable"
# A pin that is declared but not referenced is worse than no pin, because it reads as done.
for pair in "frappe-branch:FRAPPE_REF" "erpnext:ERPNEXT_REF" "hrms:HRMS_REF"; do
    target="${pair%%:*}"; var="${pair##*:}"
    if grep -qE "(--frappe-branch|--branch)[[:space:]]+\"\\\$$var\"" "$INIT_SH"; then
        ok "$target is cloned with \$$var"
    else
        bad "$target does not use \$$var in its clone argument"
    fi
done
echo

# ---------------------------------------------------------------------------
echo "T4: sah_crm remains on a branch (deliberate exception)"
# Guards the intent in both directions: if someone later pins sah_crm, this fails and forces
# the decision to be made consciously rather than by pattern-matching the apps above.
# shellcheck disable=SC2016  # single quotes are deliberate: $SAH_CRM_* must stay literal in the pattern
if grep -qE 'bench get-app "\$SAH_CRM_REPO" --branch "\$SAH_CRM_BRANCH"' "$INIT_SH"; then
    ok "sah_crm still tracks \$SAH_CRM_BRANCH -- our own app, so branch-tracking is intended"
else
    bad "sah_crm's clone changed; if pinning it was deliberate, update this test and say why"
fi
echo

# ---------------------------------------------------------------------------
echo "T5: the pre-change version was genuinely unpinned (anti-vacuity control)"
# Without this, T1 would pass just as happily against a file that never mentioned apps at all.
# A hard failure rather than a skip: a shallow CI checkout must not quietly drop the control.
BASE_REF="${PIN_TEST_BASE_REF:-origin/staging}"
if base_content="$(git -C "$(dirname "$INIT_SH")" show "$BASE_REF:docker/init.sh" 2>/dev/null)"; then
    if grep -qE '(--branch|--frappe-branch)[[:space:]]+version-1[0-9]' <<<"$base_content"; then
        ok "$BASE_REF's init.sh does use a moving branch ref -- the bug is real and T1 detects it"
    else
        bad "$BASE_REF's init.sh has no moving branch ref; this test no longer proves anything"
    fi
else
    bad "could not read $BASE_REF:docker/init.sh -- the anti-vacuity control did not run. Fetch the base ref (a shallow clone is not sufficient)."
fi
echo

echo "-----------------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
