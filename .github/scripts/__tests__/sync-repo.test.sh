#!/usr/bin/env bash
#
# Tests for .github/scripts/remote/sync-repo.sh
#
# Why this file exists
# --------------------
# The deploy step used `git pull`, which aborts on a dirty working tree. Both the prod and
# staging boxes had been hand-edited during an outage response, so every deploy from
# 22 Jul 2026 onward failed at that step. The job reported failure, nobody noticed, and the
# two environments quietly ran unmanaged code for two months.
#
# Replacing `git pull` with `git reset --hard` fixes the abort but introduces a worse
# failure mode: it destroys on-box edits with no record. On these boxes those edits were the
# only description of what production was actually running. So the reset is gated on a
# preflight, and the preflight is what these tests pin down:
#
#   * clean tree                   -> reset
#   * dirty but content == target  -> reset (nothing is lost; this was the prod case)
#   * dirty and content differs    -> ABORT unless ALLOW_DIRTY=true (this was the staging case)
#
# Untracked files must survive in every case -- `git clean -fd` is deliberately not run,
# because the untracked *.bak files on both boxes are the surviving record of the outage.
#
# Fixtures are real local git repositories. Nothing here touches a network or a server.
#
# Run:  bash .github/scripts/__tests__/sync-repo.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/../remote" && pwd)/sync-repo.sh"

passed=0
failed=0

pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

check() { # description, expected, actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

contains() { # description, needle, haystack
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (missing '$2')" ;; esac
}

lacks() { # description, needle, haystack
    case "$3" in *"$2"*) fail "$1 (found '$2')" ;; *) pass "$1" ;; esac
}

# A `sudo` stub, so the clone path can be exercised without privileges.
STUB_BIN="$(mktemp -d)"
cat > "$STUB_BIN/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
chmod +x "$STUB_BIN/sudo"
export PATH="$STUB_BIN:$PATH"

# Builds an "origin" with two commits on main and a box checkout sitting on the first.
# Returns: $ORIGIN, $BOX, $BASE_SHA, $TARGET_SHA
make_fixture() {
    local root
    root="$(mktemp -d)"

    ORIGIN="$root/origin.git"
    BOX="$root/box"

    git init --quiet --bare --initial-branch=main "$ORIGIN"

    local seed="$root/seed"
    git init --quiet --initial-branch=main "$seed"
    git -C "$seed" config user.email t@example.com
    git -C "$seed" config user.name Test
    printf 'image: frappe/bench:latest\n' > "$seed/compose.yml"
    git -C "$seed" add -A
    git -C "$seed" commit --quiet -m base
    BASE_SHA="$(git -C "$seed" rev-parse HEAD)"

    printf 'image: frappe/bench:v5.28.0\n' > "$seed/compose.yml"
    git -C "$seed" commit --quiet -am target
    TARGET_SHA="$(git -C "$seed" rev-parse HEAD)"

    git -C "$seed" push --quiet "$ORIGIN" main

    git clone --quiet "$ORIGIN" "$BOX"
    git -C "$BOX" config user.email t@example.com
    git -C "$BOX" config user.name Test
    git -C "$BOX" reset --hard --quiet "$BASE_SHA"
}

echo "Testing the deploy checkout sync: $SCRIPT_UNDER_TEST"
echo

# ---------------------------------------------------------------------------
echo "T1: clean tree behind origin fast-forwards to the target"
make_fixture
out="$(bash "$SCRIPT_UNDER_TEST" "$BOX" "$ORIGIN" main 2>&1)"; status=$?
check "exited 0" 0 "$status"
check "HEAD moved to the target" "$TARGET_SHA" "$(git -C "$BOX" rev-parse HEAD)"
contains "reported the deployed SHA" "Deployed SHA:" "$out"
echo

# ---------------------------------------------------------------------------
echo "T2: dirty tree whose content already equals the target proceeds (the prod case)"
make_fixture
# Hand-apply the target commit's content without committing it -- exactly what was found
# on the prod box: modified files, HEAD still on the old commit.
printf 'image: frappe/bench:v5.28.0\n' > "$BOX/compose.yml"
out="$(bash "$SCRIPT_UNDER_TEST" "$BOX" "$ORIGIN" main 2>&1)"; status=$?
check "exited 0" 0 "$status"
check "HEAD moved to the target" "$TARGET_SHA" "$(git -C "$BOX" rev-parse HEAD)"
check "file content is unchanged" "image: frappe/bench:v5.28.0" "$(cat "$BOX/compose.yml")"
contains "said the reset changes no content" "changes no file" "$out"
echo

# ---------------------------------------------------------------------------
echo "T3: dirty tree that differs from the target aborts (the staging case)"
make_fixture
printf 'image: frappe/bench:v5.27.0-handmade\n' > "$BOX/compose.yml"
out="$(bash "$SCRIPT_UNDER_TEST" "$BOX" "$ORIGIN" main 2>&1)"; status=$?
check "exited non-zero" 1 "$status"
check "HEAD did NOT move" "$BASE_SHA" "$(git -C "$BOX" rev-parse HEAD)"
check "the local edit survived" "image: frappe/bench:v5.27.0-handmade" "$(cat "$BOX/compose.yml")"
contains "emitted a FATAL diagnostic" "FATAL" "$out"
# VC-657: this output is a public Actions log, and an on-box edit can be a secret, so only
# the diff SUMMARY (--stat) is printed. The file name must appear; its content must not.
# (Before VC-657 this asserted the opposite -- that 'handmade' WAS printed. Flipped on purpose.)
contains "named the drifted file for review" "compose.yml" "$out"
contains "printed the --stat summary (not just git status)" "1 file changed" "$out"
lacks "did not print the drifted content" "handmade" "$out"
echo

# ---------------------------------------------------------------------------
echo "T4: ALLOW_DIRTY=true discards a differing tree deliberately"
make_fixture
printf 'image: frappe/bench:v5.27.0-handmade\n' > "$BOX/compose.yml"
out="$(bash "$SCRIPT_UNDER_TEST" "$BOX" "$ORIGIN" main true 2>&1)"; status=$?
check "exited 0" 0 "$status"
check "HEAD moved to the target" "$TARGET_SHA" "$(git -C "$BOX" rev-parse HEAD)"
check "the local edit was discarded" "image: frappe/bench:v5.28.0" "$(cat "$BOX/compose.yml")"
contains "warned before discarding" "WARNING" "$out"
contains "named the discarded file" "compose.yml" "$out"
contains "printed the --stat summary of what is discarded" "1 file changed" "$out"
lacks "did not print the discarded content" "handmade" "$out"
echo

# ---------------------------------------------------------------------------
echo "T5: untracked files survive a sync (no git clean)"
make_fixture
printf 'original\n' > "$BOX/init.sh.pre-vc409.bak"
bash "$SCRIPT_UNDER_TEST" "$BOX" "$ORIGIN" main >/dev/null 2>&1
if [ -f "$BOX/init.sh.pre-vc409.bak" ]; then
    pass "the .bak record was preserved"
else
    fail "the .bak record was deleted -- git clean must not run"
fi
echo

# ---------------------------------------------------------------------------
echo "T6: an unknown branch aborts instead of deploying stale code"
make_fixture
out="$(bash "$SCRIPT_UNDER_TEST" "$BOX" "$ORIGIN" no-such-branch 2>&1)"; status=$?
check "exited non-zero" 1 "$status"
check "HEAD did NOT move" "$BASE_SHA" "$(git -C "$BOX" rev-parse HEAD)"
contains "emitted a FATAL diagnostic" "FATAL" "$out"
echo

# ---------------------------------------------------------------------------
echo "T7: a missing checkout is cloned from scratch"
make_fixture
rm -rf "$BOX"
out="$(bash "$SCRIPT_UNDER_TEST" "$BOX" "$ORIGIN" main 2>&1)"; status=$?
check "exited 0" 0 "$status"
check "cloned at the target" "$TARGET_SHA" "$(git -C "$BOX" rev-parse HEAD)"
echo

# ---------------------------------------------------------------------------
echo "T8: the previous implementation fails on a dirty tree (anti-vacuity control)"
make_fixture
printf 'image: frappe/bench:v5.28.0\n' > "$BOX/compose.yml"
# This is verbatim what the deploy ran before: fetch, checkout, pull.
out="$( cd "$BOX" && git fetch --quiet origin && git checkout --quiet main 2>&1 && git pull origin main 2>&1 )"; status=$?
if [ "$status" -ne 0 ]; then
    pass "git pull aborts on a dirty tree -- the outage is reproduced and T2 detects it"
else
    fail "git pull succeeded; this test no longer reproduces the original failure"
fi
echo

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
