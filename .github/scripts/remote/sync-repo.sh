#!/usr/bin/env bash
#
# Bring the deployment checkout on a remote box to exactly origin/<branch>.
#
# Runs ON the target box; the deploy job pipes it in with `ssh ... bash -s -- <args>`.
# It is a standalone file rather than a heredoc so that it can be unit-tested locally
# and so that `$VAR` means the remote shell's variable, not the runner's. The previous
# inline version used an unquoted `<< EOF`, which expanded every `$VAR` on the runner.
#
# Why this exists
# ---------------
# The old step ran `git pull`, which aborts when the working tree is dirty. Both the prod
# and staging boxes had been hand-edited during an outage, so every deploy from 22 Jul 2026
# onward failed at this step and silently deployed nothing for two months.
#
# `git pull` is replaced by `git reset --hard origin/<branch>`, which cannot be blocked by
# local edits. That alone would be too blunt: it discards on-box changes with no record,
# and the hand-edits were the only description of what production was actually running.
# So a reset is gated on a preflight that classifies the drift first:
#
#   * clean tree                      -> reset (a no-op)
#   * dirty, content equals target    -> reset; the edits were the target commit applied
#                                        by hand, so nothing is lost. This is the prod case.
#   * dirty, content differs          -> ABORT and print a diff SUMMARY (--stat), unless
#                                        ALLOW_DIRTY=true. A human decides; the deploy does
#                                        not guess.
#
# Only `git diff --stat` (file names and line counts) is ever printed, never the diff body:
# this output lands in a public Actions log, and a hand-edit on the box can be a secret
# (an .env, a site_config.json). Operators review the full diff ON the box (VC-657).
#
# `git clean -fd` is deliberately NOT run. Untracked files are never overwritten by a reset,
# so they are not a correctness risk, and on both boxes the untracked `*.bak` files are the
# only surviving record of the outage response.

set -euo pipefail

DEPLOY_DIR="${1:?DEPLOY_DIR is required}"
REPO_URL="${2:?REPO_URL is required}"
BRANCH_NAME="${3:?BRANCH_NAME is required}"
ALLOW_DIRTY="${4:-false}"

echo "=== Syncing $DEPLOY_DIR to origin/$BRANCH_NAME ==="

if [ ! -d "$DEPLOY_DIR/.git" ]; then
    echo "No checkout at $DEPLOY_DIR; cloning $REPO_URL"
    sudo mkdir -p "$DEPLOY_DIR"
    sudo chown "$(id -un):$(id -gn)" "$DEPLOY_DIR"
    git clone "$REPO_URL" "$DEPLOY_DIR"
    cd "$DEPLOY_DIR"
    git checkout "$BRANCH_NAME"
    echo "Cloned at $(git rev-parse HEAD)"
    exit 0
fi

cd "$DEPLOY_DIR"

git fetch --prune origin

TARGET_REF="origin/$BRANCH_NAME"
if ! git rev-parse --verify --quiet "$TARGET_REF^{commit}" >/dev/null; then
    echo "FATAL: $TARGET_REF does not exist on the remote." >&2
    echo "Refusing to continue: deploying an unknown branch would leave the box on stale code." >&2
    exit 1
fi

TARGET_SHA="$(git rev-parse "$TARGET_REF")"
CURRENT_SHA="$(git rev-parse HEAD)"
echo "HEAD is $CURRENT_SHA"
echo "Target is $TARGET_SHA ($TARGET_REF)"

# Only tracked modifications matter. `git reset --hard` never touches untracked files,
# so they cannot be silently destroyed and must not block a deploy.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Working tree has local modifications to tracked files:"
    git status --short --untracked-files=no

    if git diff --quiet "$TARGET_SHA" --; then
        echo
        echo "These edits already match $TARGET_REF exactly, so resetting changes no file"
        echo "content -- it only moves HEAD to record what is already on disk. Proceeding."
    elif [ "$ALLOW_DIRTY" = "true" ]; then
        echo
        echo "WARNING: local edits differ from $TARGET_REF and ALLOW_DIRTY=true was set."
        echo "They will be discarded. Diff summary (working tree -> target):"
        git --no-pager diff --stat "$TARGET_SHA" -- || true
    else
        echo
        echo "FATAL: the working tree differs from $TARGET_REF and ALLOW_DIRTY was not set." >&2
        echo "Refusing to continue: these edits describe what this box is actually running," >&2
        echo "and discarding them unreviewed would destroy the only record of it." >&2
        echo "Review the full diff ON the box (git -C $DEPLOY_DIR diff $TARGET_SHA), then re-run" >&2
        echo "with ALLOW_DIRTY=true to discard it. Diff summary (working tree -> target):" >&2
        git --no-pager diff --stat "$TARGET_SHA" -- >&2 || true
        exit 1
    fi
fi

git reset --hard "$TARGET_SHA"

echo "=== Synced ==="
echo "Deployed SHA: $(git rev-parse HEAD)"
git --no-pager log -1 --format='  %h  %an  %ad  %s' --date=iso
