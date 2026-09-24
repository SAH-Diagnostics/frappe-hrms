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
# The moving-ref detector, factored out so T5 can mutation-test it (see T5 for why).
# Always exits 0; the ANSWER is what it prints, not its status.
find_moving_refs() {
    grep -nE '(--branch|--frappe-branch)[[:space:]]+"?version-1[0-9]' "$1" || true
}

echo "T1: no upstream app is cloned from a moving branch"
# `version-16` is the ref this change exists to remove. Catching it anywhere in a clone
# argument is the single most valuable assertion here, because reintroducing it silently
# restores the original bug.
moving="$(find_moving_refs "$INIT_SH")"
if [ -z "$moving" ]; then
    ok "no 'version-NN' branch ref remains in a clone argument"
else
    bad "a moving branch ref is still used:"
    while IFS= read -r line; do printf '        %s\n' "$line"; done <<<"$moving"
fi
echo

# ---------------------------------------------------------------------------
echo "T2: the pins are the versions that clear every known high/critical advisory"
# NOT "the versions production is running" -- that was the old rationale, and it is exactly
# what went wrong: production's versions carried 20 open high/critical advisories (4 critical,
# the oldest 27 days past the 14-day standard). These are the clearing versions; every
# advisory ceiling on the v16 line is `< 16.35.0`.
#
# Tags, not SHAs: `bench init --frappe-branch` and `bench get-app --branch` forward to
# `git clone --branch`, which takes a branch or tag but not an arbitrary commit.
#
# These values are DATED. When they are raised, re-run the advisory check -- a pin that is
# never revisited is worse than no pin, because it looks deliberate.
check_pin() { # var, expected
    local actual
    actual="$(grep -E "^$1=" "$INIT_SH" | sed -E 's/.*:-([^}]*)\}.*/\1/')"
    if [ "$actual" = "$2" ]; then
        ok "$1 is pinned to $2"
    else
        bad "$1 is '$actual', expected '$2'"
    fi
}
check_pin FRAPPE_REF  v16.35.0
check_pin ERPNEXT_REF v16.36.0
check_pin HRMS_REF    v16.20.0
echo

# ---------------------------------------------------------------------------
echo "T3: each pin is attached to the app it names"
# Checking that a variable is referenced SOMEWHERE is not enough, and the gap is not academic:
# swapping $ERPNEXT_REF and $HRMS_REF between the two clone lines passed every assertion in this
# file and in the advisory suite, while deploying erpnext at v16.20.0 -- inside the range of two
# CRITICAL advisories. Both variables were still "referenced", and the advisory checker could not
# see it either, because it reads the declarations and never the clone lines.
#
# So the app name and its variable must be asserted on the SAME line.
# shellcheck disable=SC2016  # single quotes deliberate: $..._REF must stay literal in the pattern
if grep -qE 'bench init .*--frappe-branch "\$FRAPPE_REF"' "$INIT_SH"; then
    ok "frappe is initialised with \$FRAPPE_REF"
else
    bad "the bench init line does not use \$FRAPPE_REF"
fi
for pair in "erpnext:ERPNEXT_REF" "hrms:HRMS_REF"; do
    target="${pair%%:*}"; var="${pair##*:}"
    if grep -qE "bench get-app --branch \"\\\$$var\" $target( |\$)" "$INIT_SH"; then
        ok "$target is cloned with \$$var -- the right pin on the right app"
    else
        bad "$target is not cloned with \$$var; the pins may be crossed between apps"
    fi
done
echo

# ---------------------------------------------------------------------------
echo "T3b: no upstream app is cloned without a pin at all"
# T1 only recognises the literal string `version-1[0-9]`, so it says nothing about an app added
# later on `--branch develop`, or one added with no `--branch` at all (which tracks the default
# branch -- the original bug, in a form T1 cannot see). Enumerate the clone lines instead of
# enumerating known-bad ref names.
unpinned=""
# shellcheck disable=SC2016  # single quotes deliberate: these are literal text patterns, not expansions
while IFS= read -r line; do
    case "$line" in
        *'$SAH_CRM_REPO'*) continue ;;       # our own app; T4 owns this exception
        *'-branch "$'*) continue ;;           # pinned via a variable (--branch or --frappe-branch)
    esac
    unpinned="${unpinned}${line}"$'\n'
done < <(grep -nE '^[[:space:]]*bench (get-app|init)' "$INIT_SH")
if [ -z "$unpinned" ]; then
    ok "every bench get-app/init line either uses a \$..._REF variable or is sah_crm"
else
    bad "an app is cloned without a pinned ref:"
    while IFS= read -r l; do [ -n "$l" ] && printf '        %s\n' "$l"; done <<<"$unpinned"
fi
echo

# ---------------------------------------------------------------------------
echo "T3c: each pin is assigned exactly once"
# The anchored `^VAR=` lookup -- used by this test AND by the advisory checker -- sees only the
# first assignment. Inserting `export FRAPPE_REF=version-16` later in the file restored the
# original moving-branch bug with all assertions in both suites still green.
for var in FRAPPE_REF ERPNEXT_REF HRMS_REF; do
    n="$(grep -cE "(^|[[:space:]]|export )$var=" "$INIT_SH")"
    if [ "$n" = "1" ]; then
        ok "$var is assigned once, so the declaration is the value that deploys"
    else
        bad "$var is assigned $n times; a later re-assignment would silently override the pin"
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
echo "T5: the moving-ref detector actually detects (anti-vacuity control)"
# Without this, T1 would pass just as happily against a file that never mentioned apps at all.
#
# The FIRST version of this control read `git show origin/staging:docker/init.sh` and asserted
# the base still contained a moving ref. That was wrong three ways, and it started failing the
# moment the fix it guarded was merged:
#   1. it broke under a shallow CI checkout, where the base blob is not fetched;
#   2. it depended on a commit surviving history rewrites, in a repo that force-pushes;
#   3. once every branch is pinned it asserts something that can never change again -- a
#      constant-true assertion dressed up as a test.
# Pinning it to a fixed SHA instead of a branch would only have moved problems 1 and 2.
#
# So: no git. Mutation-test the detector itself against two fixtures written here, which is
# what the control was always trying to prove -- that a REINTRODUCED moving ref is caught.
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

cat > "$FIXTURE_DIR/vulnerable.sh" <<'FIXTURE'
bench init --skip-redis-config-generation --frappe-branch version-16 frappe-bench
bench get-app --branch version-16 erpnext
FIXTURE

cat > "$FIXTURE_DIR/pinned.sh" <<'FIXTURE'
bench init --skip-redis-config-generation --frappe-branch "$FRAPPE_REF" frappe-bench
bench get-app --branch "$ERPNEXT_REF" erpnext
FIXTURE

# Counted, not merely non-empty. The fixture holds BOTH clone forms, so "returns something" was
# satisfied by matching either one: narrowing the detector to `--frappe-branch` only -- losing
# detection for erpnext and hrms, two of the three apps -- left this assertion green.
hits="$(find_moving_refs "$FIXTURE_DIR/vulnerable.sh" | wc -l | tr -d ' ')"
if [ "$hits" = "2" ]; then
    ok "detector flags both clone forms in the known-bad fixture (--frappe-branch and --branch)"
else
    bad "detector matched $hits of 2 known-bad lines; it covers only some of the clone forms"
fi

if [ -z "$(find_moving_refs "$FIXTURE_DIR/pinned.sh")" ]; then
    ok "detector does not flag a correctly pinned clone -- no false positive"
else
    bad "detector flagged a correctly pinned fixture; T1 would fail on good code"
fi
echo

# ---------------------------------------------------------------------------
echo "T6: container images are pinned to recordable tags"
# AC #1 of VC-648 is "record supported versions". A moving tag cannot be recorded: `redis:alpine`
# resolved to 8.10.2 on 2026-09-23 and will resolve to something else later, so a deploy's Redis
# version is unknowable after the fact. `mariadb:10.8` is deliberately NOT asserted here -- it is
# EOL and its removal from the production path is tracked with the cutover, not this change.
COMPOSE_YML="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docker-compose.yml"
check_image_pin() { # service-ish grep key, human name
    local line
    line="$(grep -E "^[[:space:]]*image:[[:space:]]*$1" "$COMPOSE_YML" || true)"
    if [ -z "$line" ]; then
        bad "$2: no image line matching '$1' found in docker-compose.yml"
    elif grep -qE "^[[:space:]]*image:[[:space:]]*$1(:latest)?[[:space:]]*$" <<<"$line"; then
        bad "$2 is unpinned (bare or :latest): $(echo "$line" | tr -d ' ')"
    elif grep -qE "[0-9]+\.[0-9]+\.[0-9]+" <<<"$line"; then
        ok "$2 is pinned to a recordable version: $(echo "$line" | tr -d ' ')"
    else
        bad "$2 has no patch-level version, so it still moves: $(echo "$line" | tr -d ' ')"
    fi
}
check_image_pin "redis" "redis"
check_image_pin "frappe/bench" "bench base image"

# A version tag is necessary but NOT sufficient, and frappe/bench is the proof. Its v5.31.0 tag
# was RELEASED on 2026-06-16 but the image behind it was rebuilt and re-pushed on 2026-09-24 --
# the same tag, a different image. Docker Hub reports the push date, and it moved. So "pinned to
# a version tag" does not mean "we can say which image ran", which is exactly what AC #1 asks for.
#
# Pinning tag@digest keeps the tag readable for a human and makes the reference immutable. It also
# means OS patches arrive only when somebody bumps it deliberately -- which is the behaviour the
# 14-day standard in the process document requires, rather than a silent refresh nobody records.
# Dependabot's docker-compose ecosystem understands this form and bumps both halves together.
bench_line="$(grep -E "^[[:space:]]*image:[[:space:]]*frappe/bench" "$COMPOSE_YML" || true)"
if grep -qE '@sha256:[0-9a-f]{64}[[:space:]]*$' <<<"$bench_line"; then
    ok "bench base image is pinned by digest, so the tag cannot be rebuilt under us"
else
    bad "bench base image has no @sha256 digest; its tag is mutable and was re-pushed in place"
fi
echo

# ---------------------------------------------------------------------------
echo "T7: the deploy records which sah_crm commit it installed"
# sah_crm cannot be pinned -- `--branch` takes a branch or a tag and the repository has zero
# tags -- so the compensating control is that every deploy PRINTS the commit it resolved. Without
# it, "which CRM code is in production?" is unanswerable after a rebuild, and its get-app failure
# is swallowed by `|| echo "Warning..."`, so a missing app looks like a clean deploy.
if grep -q 'sah_crm resolved to' "$INIT_SH"; then
    ok "init.sh echoes the resolved sah_crm commit"
else
    bad "init.sh does not record the sah_crm commit; a rebuild is unauditable"
fi
if grep -q 'sah_crm was not cloned' "$INIT_SH"; then
    # Precisely: it warns VISIBLY. It does not abort. The `|| echo "Warning..."` on the clone
    # swallows the failure, so a deploy missing sah_crm still finishes green -- the warning just
    # means a human reading the log can now tell. Making it fatal is a change to deploy behaviour
    # on a parked production system, so it is a follow-up, not part of this change.
    ok "init.sh records visibly when sah_crm is missing (it still does not abort -- see comment)"
else
    bad "a swallowed sah_crm clone failure leaves no trace at all in the deploy log"
fi
echo

# ---------------------------------------------------------------------------
echo "T8: the three pins satisfy each other's declared compatibility ranges"
# Frappe apps declare their inter-app requirements in pyproject.toml under
# [tool.bench.frappe-dependencies]. That is the only per-release compatibility statement upstream
# publishes -- there is no version matrix in the Frappe docs, only branch-level alignment
# (version-16 of each app goes together), which is far too coarse to catch what follows.
#
# bench does NOT enforce it. This was verified against bench v5.28.0, the exact image tag
# docker-compose.yml pins, in bench/app.py:
#
#   244  self.validate_app_dependencies()        <- called with no argument
#   314  def validate_app_dependencies(self, throw=False)
#   509  if sv.Version(dep_version) not in sv.SimpleSpec(req_version):
#   510      click.secho("... might not work as expected.", fg="yellow")
#   516      if throw: sys.exit(1)               <- throw is False here, so no exit
#
# A violating pin set therefore does NOT fail the deploy. It installs, prints one yellow line
# into a deploy log nobody re-reads, and leaves a subtly broken ERP behind. A missing dependency
# warns the same way, and if get_dep_version() cannot read the installed version the check is
# skipped in silence.
#
# That is the whole reason these assertions exist. If bench aborted, the deploy would fail loudly
# and CI coverage would be a convenience; because it only warns, this suite is the only thing
# between a bad bump and a quietly wrong payroll system.
#
# The constraint is not trivially satisfied, so this is not a formality. erpnext v16.36.0
# requires frappe >= 16.21.0 -- a floor well inside the v16 line. Bumping erpnext forward while
# leaving frappe behind, or rolling frappe back on its own, is exactly the plausible mistake, and
# nothing else in this repository would catch it.
#
# RECORDED, NOT FETCHED. The suite is hermetic by design, so the ranges below are a snapshot read
# from upstream at the pinned tags on 2026-09-24. **Re-read them whenever a pin moves**:
#
#   curl -sfL https://raw.githubusercontent.com/frappe/erpnext/$ERPNEXT_REF/pyproject.toml \
#     | grep -A3 'tool.bench.frappe-dependencies'
#
# The limitation is worth stating plainly rather than leaving for someone to discover: these
# assertions catch a pin that violates the RECORDED range, not a pin bumped to a tag whose real
# range has moved without the record being updated. Closing that needs a network check; it is a
# follow-up, not a reason to leave the common case unguarded.
ver_ge() { # returns 0 if $1 >= $2, comparing numerically (not lexicographically)
    # `sort | head -1` yields the SMALLER of the two, so "$1 >= $2" means the smaller one is $2.
    # Writing this the other way round tests "<=", which the self-guard below caught.
    [ "$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "${2#v}" ] \
        || [ "${1#v}" = "${2#v}" ]
}
ver_lt() { ! ver_ge "$1" "$2"; }

pin_of() { grep -E "^$1=" "$INIT_SH" | sed -E 's/.*:-([^}]*)\}.*/\1/'; }
FR="$(pin_of FRAPPE_REF)"; EN="$(pin_of ERPNEXT_REF)"; HR="$(pin_of HRMS_REF)"

# Guard the comparator itself first: a broken ver_ge would make every check below pass vacuously,
# which is the same class of defect as a fixture bound calibrated against the pin of the day.
if ver_ge "16.21.0" "16.21.0" && ver_ge "16.35.0" "16.21.0" && ver_lt "16.9.0" "16.21.0" \
   && ver_lt "16.20.0" "16.21.0" && ver_ge "16.36.0" "16.21.0"; then
    ok "the version comparator is numeric (16.9.0 < 16.21.0 <= 16.35.0)"
else
    bad "the version comparator is wrong; every compatibility assertion below is unreliable"
fi

# erpnext -> frappe:  >= 16.21.0, < 17.0.0   (erpnext v16.36.0 pyproject)
if ver_ge "$FR" "16.21.0" && ver_lt "$FR" "17.0.0"; then
    ok "frappe $FR satisfies erpnext's declared range >= 16.21.0, < 17.0.0"
else
    bad "frappe $FR does NOT satisfy erpnext's declared frappe range >= 16.21.0, < 17.0.0"
fi

# hrms -> frappe:  >= 16.0.0, < 17.0.0       (hrms v16.20.0 pyproject)
if ver_ge "$FR" "16.0.0" && ver_lt "$FR" "17.0.0"; then
    ok "frappe $FR satisfies hrms's declared range >= 16.0.0, < 17.0.0"
else
    bad "frappe $FR does NOT satisfy hrms's declared frappe range >= 16.0.0, < 17.0.0"
fi

# hrms -> erpnext:  >= 16.0.0, < 17.0.0      (hrms v16.20.0 pyproject)
if ver_ge "$EN" "16.0.0" && ver_lt "$EN" "17.0.0"; then
    ok "erpnext $EN satisfies hrms's declared range >= 16.0.0, < 17.0.0"
else
    bad "erpnext $EN does NOT satisfy hrms's declared erpnext range >= 16.0.0, < 17.0.0"
fi

# hrms/hooks.py carries `required_apps = ["frappe/erpnext"]`, so erpnext must actually be
# installed -- not merely version-compatible. Assert the deploy really clones it.
if grep -qE 'bench get-app.*erpnext' "$INIT_SH"; then
    ok "erpnext is installed, as hrms's required_apps = [\"frappe/erpnext\"] demands"
else
    bad "hrms requires erpnext but init.sh never clones it"
fi

# All three must sit on the same major line. Every range above is bounded < 17.0.0, so a mixed
# major is a guaranteed install failure regardless of which app moved.
if [ "${FR%%.*}" = "${EN%%.*}" ] && [ "${EN%%.*}" = "${HR%%.*}" ]; then
    ok "frappe, erpnext and hrms are all on the same major line (${FR%%.*})"
else
    bad "mixed major versions: frappe $FR, erpnext $EN, hrms $HR -- every declared range is < 17.0.0"
fi
echo

echo "-----------------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
