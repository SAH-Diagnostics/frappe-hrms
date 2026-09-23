#!/usr/bin/env bash
#
# Tests for .github/scripts/check-app-advisories.mjs  -- VC-648
#
# Why this file exists
# --------------------
# This checker is the only thing standing between "we have a 14-day patch process" and "we have a
# document describing one". If it reports clean when it should not, nobody finds out -- a green
# security job is not re-read. So it is tested the way a security control should be: by feeding it
# versions that MUST produce a finding and asserting they do, not merely by running it once and
# observing that it exits 0.
#
# Hermetic. ADVISORY_FIXTURE_DIR makes every case run against checked-in JSON, so the suite needs
# no network, no token, and does not change meaning when upstream publishes something new.
#
# Run:  bash .github/scripts/__tests__/check-app-advisories.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SCRIPT="$REPO_ROOT/.github/scripts/check-app-advisories.mjs"
FIXTURES="$HERE/fixtures/advisories"
FIXTURES_EMPTY="$HERE/fixtures/advisories-empty"
REAL_INIT="$REPO_ROOT/docker/init.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node is required" >&2; exit 1; }

TMP="$(mktemp -d)"
FIXTURE_DIR_HRMS="$TMP/fx-hrms"
trap 'rm -rf "$TMP"' EXIT

# Writes a throwaway init.sh carrying the three pins, in the exact shape the real file uses --
# if that shape changes, these tests stop matching and the real parser is retested for real.
make_init() { # frappe, erpnext, hrms, outfile
    cat > "$4" <<EOF
#!/bin/bash
FRAPPE_REF="\${FRAPPE_REF:-$1}"
ERPNEXT_REF="\${ERPNEXT_REF:-$2}"
HRMS_REF="\${HRMS_REF:-$3}"
EOF
}

# Runs the checker; stdout lands in $OUT, exit status in $STATUS.
run_check() { # init-file, [fixture-dir], [extra args...]
    local init="$1"; shift
    local fx="${1:-$FIXTURES}"; shift || true
    OUT="$(ADVISORY_FIXTURE_DIR="$fx" node "$SCRIPT" --init "$init" --json "$@" 2>&1)"
    STATUS=$?
}

# Does the JSON output contain this GHSA id as a finding?
has_finding() { grep -q "\"ghsa\": \"$1\"" <<<"$OUT"; }
json_num() { node -e "
  const t=process.argv[1]; const i=t.indexOf('{');
  try { console.log(JSON.parse(t.slice(i))['$1']); } catch { console.log('PARSE_ERROR'); }
" "$OUT"; }

echo "Testing advisory checker: $SCRIPT"
echo

# ---------------------------------------------------------------------------
echo "T1: the branch's own pins clear every advisory in the fixture"
run_check "$REAL_INIT"
if [ "$STATUS" -eq 0 ] && [ "$(json_num findingCount)" = "0" ]; then
    ok "docker/init.sh's pins report 0 findings and exit 0"
else
    bad "expected exit 0 / 0 findings, got exit $STATUS / $(json_num findingCount) findings"
fi
echo

# ---------------------------------------------------------------------------
echo "T2: the versions production actually ran are reported as vulnerable"
# THE anti-vacuity case. v16.29.0/v16.30.0/v16.15.0 is what production ran from 2026-07-29, and
# it carried real, published, high-and-critical advisories. A checker that cannot see these is
# not a checker.
make_init v16.29.0 v16.30.0 v16.15.0 "$TMP/old-pins.sh"
run_check "$TMP/old-pins.sh"
if [ "$STATUS" -eq 1 ]; then
    ok "exits 1 (findings) rather than 0 on the known-vulnerable set"
else
    bad "expected exit 1 on production's real versions, got $STATUS"
fi
for g in GHSA-8v98-cfpm-9p67 GHSA-6w83-8777-v93q GHSA-8pr6-r75h-h8xx GHSA-rv4r-c8v3-3hrc GHSA-v38v-9h2p-hr8v; do
    if has_finding "$g"; then ok "found $g"; else bad "missed $g -- a real advisory against the real running version"; fi
done
echo

# ---------------------------------------------------------------------------
echo "T3: mediums are filtered, withdrawn advisories are ignored, other version lines do not match"
# The medium and withdrawn controls have ranges that DO cover the pin, so each can only be
# excluded by the one rule it tests. The v15-line and lower-bound controls are different: each is
# excluded by exactly ONE clause of a range conjunction, and between them they pin both halves.
# (An earlier comment here claimed all three covered the pin. That was false for the v15-line
# control -- its UPPER bound alone already excludes a v16 pin -- which is why a parser that
# ignored every lower-bound clause used to pass the whole suite.)
if has_finding GHSA-0000-medium-ctl; then bad "a MEDIUM was reported; the severity filter is not working"; else ok "medium severity is not reported"; fi
if has_finding GHSA-0000-closed-ctl; then bad "a withdrawn (state != published) advisory was reported"; else ok "withdrawn advisories are ignored"; fi
if has_finding GHSA-0000-v15line-ctl; then bad "a v15-line advisory matched a v16 pin; the upper bound is not being applied"; else ok "a '>= 15.0.0, < 15.9.0' range does not match a v16 pin (upper bound)"; fi
if has_finding GHSA-0000-lowerbound-ctl; then bad "a '>= 16.36.0' advisory matched v16.35.0; LOWER bounds are being ignored"; else ok "a '>= 16.36.0, < 16.40.0' range does not match v16.35.0 (lower bound)"; fi
echo

# ---------------------------------------------------------------------------
echo "T4: version comparison is numeric, not lexicographic (mutation)"
# The bug this asserts against is not hypothetical -- it is the single most likely way to write
# this check wrong. As strings, "16.9.0" > "16.35.0", because '9' > '3'. A lexicographic
# implementation therefore declares v16.9.0 -- six minor versions BEHIND, carrying every advisory
# in the file -- to be clean, and does so only for the versions that are furthest out of date.
make_init v16.9.0 v16.35.0 v16.20.0 "$TMP/lexico.sh"
run_check "$TMP/lexico.sh"
if has_finding GHSA-8v98-cfpm-9p67 && [ "$STATUS" -eq 1 ]; then
    ok "v16.9.0 is correctly seen as older than 16.30.0"
else
    bad "v16.9.0 was NOT flagged (exit $STATUS) -- versions are being compared as strings"
fi
echo

# ---------------------------------------------------------------------------
echo "T5: the 14-day standard is computed, not assumed"
make_init v16.29.0 v16.30.0 v16.15.0 "$TMP/sla.sh"
run_check "$TMP/sla.sh"
# Captured and type-checked first: `[ "$(json_num x)" -ge 1 ] 2>/dev/null` swallowed bash's
# "integer expression expected", so unparseable output reported as "nothing is overdue" rather
# than as the parse failure it was.
OVERDUE="$(json_num overdueCount)"
if ! [[ "$OVERDUE" =~ ^[0-9]+$ ]]; then
    bad "overdueCount did not parse as a number (got '$OVERDUE') -- the checker's output is malformed"
elif [ "$OVERDUE" -ge 1 ]; then
    ok "advisories published 2026-08-13 are counted as past the 14-day standard"
else
    bad "nothing counted as overdue, though the fixture holds advisories from 2026-08-13"
fi
# A generous SLA must move the answer; if it does not, the number is decorative.
OUT="$(ADVISORY_FIXTURE_DIR="$FIXTURES" node "$SCRIPT" --init "$TMP/sla.sh" --json --sla-days 100000 2>&1)"
if [ "$(json_num overdueCount)" = "0" ]; then
    ok "--sla-days 100000 drops the overdue count to 0 -- the arithmetic is real"
else
    bad "overdue count ignored --sla-days; the SLA figure is not actually computed"
fi
echo

# ---------------------------------------------------------------------------
echo "T6: it fails rather than passing when it cannot do its job"
# Every case here is a way the check could stop working silently. Each must exit 2 -- distinct
# from both 0 (clean) and 1 (findings), so a broken check can never be read as a clean one.

printf '#!/bin/bash\necho "no pins here"\n' > "$TMP/no-pins.sh"
run_check "$TMP/no-pins.sh"
if [ "$STATUS" -eq 2 ]; then ok "missing pins exit 2"; else bad "missing pins exited $STATUS, expected 2"; fi
# Asserting only the exit code is too weak: with the pin check downgraded to a warning the script
# still exits 2, but several frames later and with the message "pinned ref 'undefined' is not a
# version" -- true, useless, and it sends the reader to the wrong file. The operator needs to be
# told the pins are GONE, because that means the apps are on a moving branch again.
if grep -q "ERROR: no pin found" <<<"$OUT" && grep -q "moving branch" <<<"$OUT"; then
    ok "and it says WHICH pin is missing, what that implies, and that it is fatal"
else
    bad "the missing-pin message is not a fatal ERROR naming the pin and the consequence: ${OUT:0:160}"
fi
# "ERROR:" rather than any wording: downgrading this to a warning still exits 2 (the version
# parser trips over the undefined pin a moment later) and still prints the same sentence, so an
# exit-code assertion alone cannot tell the two apart. What changes is whether the line reads as
# fatal to someone scanning a job log -- which is the only place this message is ever read.

make_init "version-16" v16.35.0 v16.20.0 "$TMP/garbage.sh"
run_check "$TMP/garbage.sh"
if [ "$STATUS" -eq 2 ]; then ok "an uncomparable ref ('version-16') exits 2 rather than being skipped"; else bad "garbage ref exited $STATUS, expected 2"; fi

run_check "$REAL_INIT" "$FIXTURES_EMPTY"
if [ "$STATUS" -eq 2 ]; then
    ok "an empty advisory feed exits 2 -- 'could not look' never reports as 'nothing found'"
else
    bad "empty feed exited $STATUS, expected 2; this check would turn permanently green if the API changed"
fi

run_check "$TMP/does-not-exist.sh"
if [ "$STATUS" -eq 2 ]; then ok "a missing init.sh exits 2"; else bad "missing init.sh exited $STATUS, expected 2"; fi
echo

# ---------------------------------------------------------------------------
echo "T7: an unparseable version range escalates instead of being skipped"
# An advisory whose range the parser does not understand is an UNKNOWN. Treating an unknown as
# safe is how a checker quietly narrows its own coverage as upstream's format drifts.
mkdir -p "$TMP/fx-unparsed"
cp "$FIXTURES"/frappe-erpnext.json "$FIXTURES"/frappe-hrms.json "$TMP/fx-unparsed/"
cat > "$TMP/fx-unparsed/frappe-frappe.json" <<'EOF'
[
  { "ghsa_id": "GHSA-0000-unparsed-ctl", "severity": "critical", "state": "published",
    "published_at": "2026-09-01T00:00:00Z", "summary": "Synthetic -- range format the parser does not know",
    "vulnerabilities": [ { "package": { "ecosystem": "pip", "name": "frappe" }, "vulnerable_version_range": "sometime around 16ish" } ] }
]
EOF
run_check "$REAL_INIT" "$TMP/fx-unparsed"
if has_finding GHSA-0000-unparsed-ctl && [ "$STATUS" -eq 1 ]; then
    ok "an unrecognised range is reported as a finding, not silently dropped"
else
    bad "an unrecognised range was skipped (exit $STATUS); coverage would shrink silently as the format drifts"
fi
# The finding must also SAY the range was not understood. Without the marker the report claims a
# version match it never actually made, which is a worse failure than dropping the advisory: it
# looks like knowledge.
if grep -q '"unparsedRange": true' <<<"$OUT"; then
    ok "the finding is marked as an unparsed range rather than passed off as a real match"
else
    bad "the finding does not carry unparsedRange; a range the parser failed on reads as understood"
fi
echo

# ---------------------------------------------------------------------------
echo "T8: a fixture run can never be mistaken for a live one"
HUMAN="$(ADVISORY_FIXTURE_DIR="$FIXTURES" node "$SCRIPT" --init "$REAL_INIT" 2>&1)"
if grep -q "NOT a live check" <<<"$HUMAN"; then
    ok "fixture mode announces itself in the human-readable output"
else
    bad "fixture mode is indistinguishable from a live run -- evidence from it could be cited as real"
fi
echo


# ---------------------------------------------------------------------------
echo "T9: all three applications are actually covered"
# Without this the suite was structurally blind to one of them: every GHSA asserted in T2 belongs
# to frappe or erpnext, so DELETING hrms from the checker entirely passed all 21 assertions. A
# suite that cannot notice an app has stopped being checked is not covering that app.
HUMAN_ALL="$(ADVISORY_FIXTURE_DIR="$FIXTURES" node "$SCRIPT" --init "$REAL_INIT" 2>&1)"
for app in frappe erpnext hrms; do
    if grep -qE "^  $app( |$)" <<<"$HUMAN_ALL"; then
        ok "$app is listed among the checked applications"
    else
        bad "$app is NOT checked; the checker silently stopped covering it"
    fi
done

# ...and hrms findings are genuinely detected, not merely listed. hrms had no real high/critical
# advisory, so this fixture is synthetic and lives here rather than in the shared set.
mkdir -p "$FIXTURE_DIR_HRMS"
cp "$FIXTURES/frappe-frappe.json" "$FIXTURES/frappe-erpnext.json" "$FIXTURE_DIR_HRMS/"
cat > "$FIXTURE_DIR_HRMS/frappe-hrms.json" <<'EOF'
[
  { "_synthetic": "NOT A REAL ADVISORY. hrms had no high/critical advisory on 2026-09-23. This exists only to prove the hrms path can produce a finding at all.",
    "ghsa_id": "GHSA-0000-hrms-high-ctl", "severity": "critical", "state": "published",
    "published_at": "2026-09-01T00:00:00Z", "summary": "Synthetic hrms critical",
    "vulnerabilities": [ { "package": { "ecosystem": "pip", "name": "hrms" }, "vulnerable_version_range": ">= 16.0.0, < 16.18.0", "patched_versions": "16.18.0" } ] }
]
EOF
make_init v16.35.0 v16.35.0 v16.15.0 "$TMP/hrms-old.sh"
run_check "$TMP/hrms-old.sh" "$FIXTURE_DIR_HRMS"
if has_finding GHSA-0000-hrms-high-ctl; then ok "an hrms advisory affecting v16.15.0 is reported"; else bad "the hrms path produced no finding for an advisory that covers its pin"; fi
run_check "$REAL_INIT" "$FIXTURE_DIR_HRMS"
if has_finding GHSA-0000-hrms-high-ctl; then bad "v16.20.0 was reported against a '< 16.18.0' range"; else ok "and v16.20.0 clears it"; fi
echo

# ---------------------------------------------------------------------------
echo "T10: an advisory is counted once, however many package entries it lists"
# The headline count goes into the compliance record, so double-counting is not cosmetic. Every
# shared fixture advisory has a single entry, which made the dedup an untestable no-op.
mkdir -p "$TMP/fx-twoentry"
cp "$FIXTURES/frappe-frappe.json" "$FIXTURES/frappe-hrms.json" "$TMP/fx-twoentry/"
cat > "$TMP/fx-twoentry/frappe-erpnext.json" <<'EOF'
[
  { "_synthetic": "NOT A REAL ADVISORY -- two overlapping entries for the same package.",
    "ghsa_id": "GHSA-0000-twoentry-ctl", "severity": "high", "state": "published",
    "published_at": "2026-09-10T00:00:00Z", "summary": "Synthetic two-entry high",
    "vulnerabilities": [
      { "package": { "ecosystem": "pip", "name": "erpnext" }, "vulnerable_version_range": ">= 16.0.0, < 16.90.0", "patched_versions": "16.90.0" },
      { "package": { "ecosystem": "pip", "name": "erpnext" }, "vulnerable_version_range": ">= 16.0.0, < 16.91.0", "patched_versions": "16.91.0" } ] }
]
EOF
run_check "$REAL_INIT" "$TMP/fx-twoentry"
if [ "$(json_num findingCount)" = "1" ]; then
    ok "a two-entry advisory yields exactly one finding"
else
    bad "a two-entry advisory yielded $(json_num findingCount) findings; the headline count inflates"
fi

# The matched path breaks after its first hit, so the case above is carried by the `break` alone.
# The UNPARSED path continues instead -- it has to, since an unparseable range proves nothing
# about the others -- so only an explicit per-advisory guard stops two bad ranges from being
# counted twice. Without this case, removing that guard changes nothing observable.
mkdir -p "$TMP/fx-twonull"
cp "$FIXTURES/frappe-erpnext.json" "$FIXTURES/frappe-hrms.json" "$TMP/fx-twonull/"
cat > "$TMP/fx-twonull/frappe-frappe.json" <<'EOF'
[
  { "_synthetic": "NOT A REAL ADVISORY -- two entries whose ranges the parser cannot read.",
    "ghsa_id": "GHSA-0000-twonull-ctl", "severity": "critical", "state": "published",
    "published_at": "2026-09-01T00:00:00Z", "summary": "Synthetic unparseable-range critical",
    "vulnerabilities": [
      { "package": { "ecosystem": "pip", "name": "frappe" }, "vulnerable_version_range": "tbd" },
      { "package": { "ecosystem": "pip", "name": "frappe" }, "vulnerable_version_range": "sometime around 16ish" } ] }
]
EOF
run_check "$REAL_INIT" "$TMP/fx-twonull"
if [ "$(json_num findingCount)" = "1" ]; then
    ok "an advisory with two unparseable ranges is still counted once"
else
    bad "two unparseable ranges produced $(json_num findingCount) findings for one advisory"
fi
echo

# ---------------------------------------------------------------------------
echo "T11: a version this checker cannot compare is refused, never truncated"
# The regex used to be unanchored, so `v16.35.0-beta.1` parsed to [16,35,0] -- EQUAL to the
# release that fixes an advisory -- and a pre-release that predates the fix reported clean.
# Frappe ships `-beta` tags, so this is a reachable pin value, and silently comparing it is the
# same false-negative class as comparing versions as strings.
for badver in v16.35.0-beta.1 v16.35.0rc1 v16.35.0.1 v16.35 latest; do
    make_init "$badver" v16.35.0 v16.20.0 "$TMP/ver.sh"
    run_check "$TMP/ver.sh"
    if [ "$STATUS" -eq 2 ]; then ok "pin '$badver' is refused (exit 2) rather than silently truncated"; else bad "pin '$badver' exited $STATUS; it was compared as if it were a release"; fi
done
echo

# ---------------------------------------------------------------------------
echo "T12: an exact-version range is understood"
# GitHub writes these without an operator -- a bare `16.11.0` -- and that form is live in the
# frappe and hrms feeds today. Requiring an operator turned each one into an 'unparseable range',
# which this checker escalates, so an unaffected pin was reported as a finding.
mkdir -p "$TMP/fx-bare"
cp "$FIXTURES/frappe-erpnext.json" "$FIXTURES/frappe-hrms.json" "$TMP/fx-bare/"
cat > "$TMP/fx-bare/frappe-frappe.json" <<'EOF'
[
  { "_synthetic": "NOT A REAL ADVISORY -- operator-less exact-version range, matching the pin.",
    "ghsa_id": "GHSA-0000-exact-hit", "severity": "critical", "state": "published",
    "published_at": "2026-09-01T00:00:00Z", "summary": "Synthetic exact-version critical",
    "vulnerabilities": [ { "package": { "ecosystem": "pip", "name": "frappe" }, "vulnerable_version_range": "16.35.0" } ] },
  { "_synthetic": "NOT A REAL ADVISORY -- operator-less exact-version range, NOT matching the pin.",
    "ghsa_id": "GHSA-0000-exact-miss", "severity": "critical", "state": "published",
    "published_at": "2026-09-01T00:00:00Z", "summary": "Synthetic exact-version critical",
    "vulnerabilities": [ { "package": { "ecosystem": "pip", "name": "frappe" }, "vulnerable_version_range": "16.11.0" } ] }
]
EOF
run_check "$REAL_INIT" "$TMP/fx-bare"
if has_finding GHSA-0000-exact-hit; then ok "a bare '16.35.0' range matches the pin v16.35.0"; else bad "a bare exact-version range did not match an identical pin"; fi
if has_finding GHSA-0000-exact-miss; then bad "a bare '16.11.0' range matched pin v16.35.0"; else ok "a bare '16.11.0' range does not match v16.35.0"; fi
if grep -q '"unparsedRange": true' <<<"$OUT"; then bad "an exact-version range is still being treated as unparseable"; else ok "and neither is escalated as an unparsed range"; fi
echo

# ---------------------------------------------------------------------------
echo "T13: one dead feed cannot hide behind two live ones"
# The liveness guard used to test the SUM across all three repositories, so frappe returning an
# empty array while erpnext returned anything at all produced 'No high or critical advisory
# affects the pinned versions', exit 0, with frappe never actually checked.
mkdir -p "$TMP/fx-onedead"
cp "$FIXTURES/frappe-erpnext.json" "$FIXTURES/frappe-hrms.json" "$TMP/fx-onedead/"
echo '[]' > "$TMP/fx-onedead/frappe-frappe.json"
run_check "$REAL_INIT" "$TMP/fx-onedead"
if [ "$STATUS" -eq 2 ] && grep -q "frappe/frappe returned zero" <<<"$OUT"; then
    ok "a single empty feed exits 2 and names the repository that went quiet"
else
    bad "one dead feed exited $STATUS; two live feeds were enough to report a clean result"
fi
echo

# ---------------------------------------------------------------------------
echo "T14: the remaining ways the check could stop working silently"
mkdir -p "$TMP/fx-badjson"
cp "$FIXTURES"/*.json "$TMP/fx-badjson/"
printf 'not json' > "$TMP/fx-badjson/frappe-frappe.json"
run_check "$REAL_INIT" "$TMP/fx-badjson"
if [ "$STATUS" -eq 2 ]; then ok "an unreadable advisory payload exits 2"; else bad "unreadable payload exited $STATUS, expected 2"; fi

# NaN silently DISABLES the standard: every overdueBy becomes NaN, nothing compares above zero,
# and the report states '0 past the NaN-day standard' while still exiting 1.
for badsla in abc "" -5 "14 days"; do
    OUT="$(ADVISORY_FIXTURE_DIR="$FIXTURES" node "$SCRIPT" --init "$REAL_INIT" --json --sla-days "$badsla" 2>&1)"; STATUS=$?
    if [ "$STATUS" -eq 2 ]; then ok "--sla-days '$badsla' is refused"; else bad "--sla-days '$badsla' exited $STATUS; the 14-day standard was silently disabled"; fi
done

# `env -u ALLOW_FIXTURES_IN_CI` is load-bearing. The workflow sets that variable for the whole
# self-test step so this suite can replay fixtures at all, and a step-level env is inherited by
# every child process -- including this one, whose entire point is to prove the guard still
# refuses. Without the unset, the assertion below silently tests the opt-out instead of the
# guard, and fails in CI while passing on a developer's machine.
OUT="$(env -u ALLOW_FIXTURES_IN_CI ADVISORY_FIXTURE_DIR="$FIXTURES" GITHUB_ACTIONS=1 node "$SCRIPT" --init "$REAL_INIT" 2>&1)"; STATUS=$?
if [ "$STATUS" -eq 2 ]; then
    ok "fixture mode is refused under GITHUB_ACTIONS -- a CI run cannot be a fixture replay"
else
    bad "fixtures were replayed under GITHUB_ACTIONS (exit $STATUS); a repo-level env var could fake a clean live check"
fi
echo

# ---------------------------------------------------------------------------
echo "T15: the overdue boundary is where the standard says it is"
# Without a boundary case, widening the comparison from `> 0` to `>= 0` changed nothing
# detectable. Measured against an SLA equal to an advisory's exact age it is due TODAY, not
# overdue; one day tighter and it is. Derived from the fixture rather than hardcoded, so the
# assertion does not rot as the fixture dates recede.
make_init v16.29.0 v16.30.0 v16.15.0 "$TMP/boundary.sh"
run_check "$TMP/boundary.sh"
AGE="$(node -e '
  let d = ""; process.stdin.on("data", c => d += c).on("end", () => {
    const j = JSON.parse(d.slice(d.indexOf("{")));
    const f = j.findings.find(x => x.ghsa === "GHSA-v38v-9h2p-hr8v");
    console.log(f && Number.isInteger(f.ageDays) ? f.ageDays : "");
  });' <<<"$OUT")"

if ! [[ "$AGE" =~ ^[0-9]+$ ]]; then
    bad "could not read ageDays for the boundary case (got '$AGE')"
else
    OUT="$(ADVISORY_FIXTURE_DIR="$FIXTURES" node "$SCRIPT" --init "$TMP/boundary.sh" --json --sla-days "$AGE" 2>&1)"
    AT_SLA="$(json_num overdueCount)"
    TIGHTER=$((AGE - 1))
    OUT="$(ADVISORY_FIXTURE_DIR="$FIXTURES" node "$SCRIPT" --init "$TMP/boundary.sh" --json --sla-days "$TIGHTER" 2>&1)"
    PAST_SLA="$(json_num overdueCount)"
    if [ "$PAST_SLA" -gt "$AT_SLA" ]; then
        ok "at SLA=$AGE days the advisory is not yet overdue; at SLA=$TIGHTER it is"
    else
        bad "the boundary does not move: overdue was $AT_SLA at SLA=$AGE and $PAST_SLA at SLA=$TIGHTER"
    fi
fi
echo

# ---------------------------------------------------------------------------
echo "T16: the workflow that delivers this control is itself guarded"
# Nothing asserted anything about the workflow, so the delivery mechanism of the whole control was
# unprotected. The sharpest example: changing `status=${PIPESTATUS[0]}` to `status=$?` makes the
# job read tee's always-zero exit and turn PERMANENTLY GREEN regardless of findings -- and every
# assertion in both suites still passed.
WF="$REPO_ROOT/.github/workflows/security-advisory-check.yml"
if [ ! -f "$WF" ]; then
    bad "the advisory workflow is missing; the checker runs nowhere"
else
    # Anchored to the ASSIGNMENT, not to any occurrence. A bare `grep PIPESTATUS` was satisfied
    # by the comment that explains why PIPESTATUS is used, so the assertion passed against a
    # workflow whose code had been changed to `status=$?` -- the exact mutation it exists to catch.
    if grep -qE '^[[:space:]]*status=\$\{PIPESTATUS\[0\]\}' "$WF"; then
        ok "the job assigns the checker's exit status, not the last command in the pipe"
    else
        bad "status is not assigned from PIPESTATUS[0] -- with a 'tee' pipe the job is permanently green"
    fi
    # shellcheck disable=SC2016  # literal pattern: we are grepping for the text '$status'
    if grep -qE '^\s*exit "\$status"' "$WF"; then
        ok "and it exits with that status"
    else
        bad "the workflow does not exit with the checker's status"
    fi
    if grep -q 'check-app-advisories.test.sh' "$WF" && grep -q 'init-app-pins.test.sh' "$WF"; then
        ok "both anti-vacuity suites run before the live check"
    else
        bad "a self-test suite is not wired into the workflow; its assertions cannot fail CI"
    fi
    if grep -qE '2>&1 \| tee' "$WF"; then
        ok "stderr is captured, so an exit-2 run records WHY in the evidence artifact"
    else
        bad "only stdout is captured; a failed check would be evidenced as two header lines and no reason"
    fi
    if grep -q 'continue-on-error' "$WF"; then
        bad "continue-on-error is set somewhere in this workflow; a finding would not fail the job"
    else
        ok "no continue-on-error, so a finding actually fails the job"
    fi
    if grep -qE '^\s*contents:\s*read' "$WF"; then
        ok "the job token is scoped to contents: read"
    else
        bad "no least-privilege permissions block; a security check should not hold write scope"
    fi
fi
echo

echo "T17: the CI fixture guard is opted out of for the self-test step ONLY"
# Regression test for a bug this suite could not catch locally, because the guard it exercises
# only fires when GITHUB_ACTIONS is set.
#
# check-app-advisories.mjs refuses ADVISORY_FIXTURE_DIR under GITHUB_ACTIONS, so a live check can
# never be satisfied by canned data. That guard also caught THIS suite, whose whole job is to
# replay fixtures -- so every fixture-backed assertion returned exit 2 in CI and 21 of them
# failed, while all 51 passed locally.
#
# The fix is an opt-in on the self-test step alone. The danger in that fix is hoisting it: an
# ALLOW_FIXTURES_IN_CI at job or workflow level would also disable the guard on "Check the pinned
# versions", turning the live security check into a fixture replay that reports success forever.
# That is the exact fail-open this workflow exists to prevent, so it is asserted, not trusted.
if [ ! -f "$WF" ]; then
    bad "workflow not found at $WF"
else
    if python3 - "$WF" <<'PYEOF'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
# A step-level env sits at 8 spaces of indent under a "- name:" at 6. Job/workflow level sits
# at 0-6. Anything at <= 6 spaces is a hoist.
hoisted = [l for l in lines
           if re.match(r"^ {0,6}ALLOW_FIXTURES_IN_CI\s*:", l)]
sys.exit(1 if hoisted else 0)
PYEOF
    then
        ok "ALLOW_FIXTURES_IN_CI is not set at job or workflow level"
    else
        bad "ALLOW_FIXTURES_IN_CI is hoisted to job/workflow level -- the LIVE check would replay fixtures"
    fi

    # The live step must not carry it either, even as a step-level value.
    if awk '/^      - name: Check the pinned versions/{f=1;next} /^      - name:/{f=0} f' "$WF" \
         | grep -q 'ALLOW_FIXTURES_IN_CI'; then
        bad "the live 'Check the pinned versions' step sets ALLOW_FIXTURES_IN_CI -- it would accept canned data"
    else
        ok "the live check step does not opt out of the fixture guard"
    fi

    # And the self-test step must carry it, or CI fails the way it just did.
    if awk '/^      - name: Self-test the checker/{f=1;next} /^      - name:/{f=0} f' "$WF" \
         | grep -q "ALLOW_FIXTURES_IN_CI: '1'"; then
        ok "the self-test step opts in, so the fixture suite can run under GITHUB_ACTIONS"
    else
        bad "the self-test step does not set ALLOW_FIXTURES_IN_CI; every fixture assertion will exit 2 in CI"
    fi
fi
echo

echo "-----------------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
