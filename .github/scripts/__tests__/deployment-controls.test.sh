#!/usr/bin/env bash
#
# Deployment controls for the SAH-owned workflows and scripts under .github/ and docker/.
#
# Ticket: VC-649, Secure ERP CI/CD and deployment secrets.
#
# Why this file exists
# --------------------
# This repository is public. Every retained deploy run in 2026 printed the Lightsail SSH
# private key, and the production runs also printed the Frappe encryption key, in clear
# text in a log anyone could download. The path was a "Load secrets as environment
# variables" step that re-parsed the file fetched from AWS Secrets Manager with
# `IFS='=' read -r key value` and appended the result to $GITHUB_ENV. That parse drops a
# single trailing `=` from a value, so the copy written to $GITHUB_ENV differed from the
# value the fetch script had registered with ::add-mask::, and the runner's step-header
# environment dump printed the unmasked variant. Nothing ever read the $GITHUB_ENV copy:
# every consuming step sources secrets.env itself.
#
# Each assertion below pins one control so the exposure cannot quietly return:
#
#   T1  least-privilege GITHUB_TOKEN: exactly one top-level permissions block, contents: read,
#       and no job- or step-level permissions block that could widen it
#   T2  every credential-holding job is bound to its GitHub Environment (approvals/secrets);
#       one job per workflow, so a second job cannot sidestep the binding
#   T3  no workflow writes to $GITHUB_ENV (the only sink where unmasked values reached a log)
#   T4  every action is pinned to a full commit SHA with a version comment (supply chain)
#   T5  each workflow references exactly its own environment's four repository secrets, by
#       name only (no toJSON(secrets), secrets[...] or secrets: inherit)
#   T6  no credential-shaped literal anywhere under .github/, docker/ or scripts/; each root
#       must exist and contribute files, and at least 45 text files must be scanned
#   T7  fetch-aws-secrets.sh still registers every fetched value with ::add-mask:: (both parsers)
#   T8  .gitignore keeps .env*, *.pem, *.key and the act-local .secrets file out of git
#   T9  CODEOWNERS names only current SAH reviewers and covers the deploy-relevant paths
#   T10 setup-aws-cli.sh no longer prints the AWS account id / IAM ARN into the public log
#   T11 generate-env-file.sh no longer writes the deploy-scope AWS keys onto the box
#   T12 the sah_crm branch is chosen per environment by its deploy workflow and reaches the
#       container through compose, so promoting staging to main cannot ship staging's value
#
# REPO_ROOT can be overridden to run the same assertions against another checkout, which is
# how red-on-base and mutation runs are produced. Nothing here touches a network or AWS.
#
# Run:  bash .github/scripts/__tests__/deployment-controls.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
SAH_WORKFLOWS="deploy-prod.yml deploy-staging.yml deploy-dev.yml configure-nginx-prod.yml configure-nginx-staging.yml configure-nginx-dev.yml"
CONTROLS_WORKFLOW="deployment-controls.yml"

ALLOWED_OWNERS="@mohammad-dasseh @alitamoor-dev"
SCAN_ROOTS=".github docker scripts"
MIN_SCANNED_FILES=45

passed=0
failed=0

pass() { echo "  PASS $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL $1"; failed=$((failed + 1)); }

check() { # description, expected, actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# Working copies on Windows may be CRLF (core.autocrlf); every read goes through this.
lf() { tr -d '\r' < "$1"; }

# A missing file is a failure, never a skip.
require_file() { # test id, path
    if [ -f "$2" ]; then return 0; fi
    fail "$1 ${2#"$REPO_ROOT"/}: file missing"
    return 1
}

expected_environment() {
    case "$1" in
        *-prod*)    echo production ;;
        *-staging*) echo staging ;;
        *-dev*)     echo development ;;
    esac
}

expected_secret_prefix() {
    case "$1" in
        *-prod*)    echo PROD_ ;;
        *-staging*) echo STAGING_ ;;
        *-dev*)     echo DEV_ ;;
    esac
}

echo "Deployment controls under: $REPO_ROOT"
echo

# ---------------------------------------------------------------------------
echo "T1: one top-level permissions block per workflow, contents: read, nothing else writable"
for wf in $SAH_WORKFLOWS; do
    path="$WORKFLOW_DIR/$wf"
    require_file T1 "$path" || continue
    headers="$(lf "$path" | grep -cE '^permissions:')"
    bare_headers="$(lf "$path" | grep -cE '^permissions:[[:space:]]*$')"
    if [ "$headers" != "1" ] || [ "$bare_headers" != "1" ]; then
        fail "T1 $wf: expected exactly one bare column-0 'permissions:' block (found $headers header(s), $bare_headers bare)"
        continue
    fi
    block="$(lf "$path" | awk '
        /^permissions:/ { inblock = 1; next }
        inblock && /^[^[:space:]]/ { inblock = 0 }
        inblock { print }
    ' | grep -vE '^[[:space:]]*(#|$)')"
    has_contents_read="$(printf '%s\n' "$block" | grep -cE '^  contents: read[[:space:]]*$')"
    disallowed="$(printf '%s\n' "$block" | grep -vE '^  (contents: read|id-token: write)[[:space:]]*$' | grep -c .)"
    if [ "$has_contents_read" = "1" ] && [ "$disallowed" = "0" ]; then
        pass "T1 $wf: permissions block is {contents: read} (id-token: write allowed)"
    else
        fail "T1 $wf: permissions block must be a subset of {contents: read, id-token: write} and contain contents: read (contents-read lines: $has_contents_read, disallowed keys: $disallowed)"
    fi
    nested="$(lf "$path" | grep -cE '^[[:space:]]+permissions:')"
    check "T1 $wf: no job- or step-level permissions block" 0 "$nested"
done
echo

# ---------------------------------------------------------------------------
echo "T2: every credential-holding job is bound to its environment"
for wf in $SAH_WORKFLOWS; do
    path="$WORKFLOW_DIR/$wf"
    require_file T2 "$path" || continue
    env_name="$(expected_environment "$wf")"
    count="$(lf "$path" | grep -Ec "^    environment: ${env_name}[[:space:]]*$")"
    check "T2 $wf: 'environment: $env_name' exactly once" 1 "$count"
    jobs="$(lf "$path" | awk '
        /^jobs:/ { injobs = 1; next }
        injobs && /^[^[:space:]]/ { injobs = 0 }
        injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { n++ }
        END { print n + 0 }
    ')"
    check "T2 $wf: exactly one job, so the environment binding covers every step" 1 "$jobs"
done
echo

# ---------------------------------------------------------------------------
echo "T3: no workflow writes to GITHUB_ENV"
for wf in $SAH_WORKFLOWS; do
    path="$WORKFLOW_DIR/$wf"
    require_file T3 "$path" || continue
    count="$(lf "$path" | grep -c GITHUB_ENV)"
    check "T3 $wf: no GITHUB_ENV" 0 "$count"
done
echo

# ---------------------------------------------------------------------------
echo "T4: every action is pinned to a full commit SHA with a version comment"
PIN_RE='^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]+(\.[0-9]+){0,2}[[:space:]]*$'
for wf in $SAH_WORKFLOWS $CONTROLS_WORKFLOW; do
    path="$WORKFLOW_DIR/$wf"
    require_file T4 "$path" || continue
    total="$(lf "$path" | grep -cE '^[[:space:]]*-?[[:space:]]*uses:')"
    pinned="$(lf "$path" | grep -cE "$PIN_RE")"
    if [ "$total" -lt 1 ]; then
        fail "T4 $wf: no 'uses:' lines found (vacuous)"
    elif [ "$pinned" = "$total" ]; then
        pass "T4 $wf: all $total 'uses:' pinned to a 40-hex SHA with a version comment"
    else
        fail "T4 $wf: $((total - pinned)) of $total 'uses:' lines are not SHA-pinned"
    fi
done
echo

# ---------------------------------------------------------------------------
echo "T5: each workflow references exactly its own environment's repository secrets"
for wf in $SAH_WORKFLOWS; do
    path="$WORKFLOW_DIR/$wf"
    require_file T5 "$path" || continue
    prefix="$(expected_secret_prefix "$wf")"
    actual="$(lf "$path" | grep -oE '\$\{\{[[:space:]]*secrets\.[A-Za-z0-9_]+' | sed 's/.*secrets\.//' | sort -u | tr '\n' ' ')"
    expected="$(printf '%s\n' AWS_SECRETS_REGION "${prefix}AWS_ACCESS_KEY_ID" "${prefix}AWS_SECRETS_ACCESS_KEY" "${prefix}AWS_DEPLOY_SECRET_ID" | sort -u | tr '\n' ' ')"
    check "T5 $wf: secrets referenced == {${expected% }}" "$expected" "$actual"
    bulk="$(lf "$path" | grep -cE 'toJSON\(secrets\)|secrets\[|secrets:[[:space:]]*inherit')"
    check "T5 $wf: no bulk or indirect secrets access" 0 "$bulk"
done
echo

# ---------------------------------------------------------------------------
echo "T6: no credential-shaped literal under .github/, docker/ or scripts/"
scan_files=()
roots_ok=1
for root in $SCAN_ROOTS; do
    if [ ! -d "$REPO_ROOT/$root" ]; then
        fail "T6 scan root $root/ is missing"
        roots_ok=0
        continue
    fi
    root_files="$(find "$REPO_ROOT/$root" -type f | xargs -r grep -Il . | wc -l | tr -d ' ')"
    if [ "$root_files" -ge 1 ]; then
        pass "T6 scan root $root/ contributes $root_files text file(s)"
    else
        fail "T6 scan root $root/ contributes no text files"
        roots_ok=0
    fi
    while IFS= read -r f; do
        if [ "$f" -ef "$SELF" ]; then continue; fi
        scan_files+=("$f")
    done < <(find "$REPO_ROOT/$root" -type f | sort)
done

if [ "$roots_ok" -eq 0 ] || [ "${#scan_files[@]}" -eq 0 ]; then
    fail "T6 scan skipped: every root in {$SCAN_ROOTS} must exist and contain text files"
else
    scanned="$(grep -Il . "${scan_files[@]}" | wc -l | tr -d ' ')"
    echo "  scanned $scanned text file(s) (excluding this script)"
    if [ "$scanned" -ge "$MIN_SCANNED_FILES" ]; then
        pass "T6 scanned $scanned files (>= $MIN_SCANNED_FILES, non-vacuous)"
    else
        fail "T6 scanned only $scanned files (< $MIN_SCANNED_FILES) -- the scan is vacuous"
    fi

    scan() { # test label, grep flags, pattern
        local label="$1" flags="$2" pattern="$3" hits
        hits="$(grep -Il $flags -- "$pattern" "${scan_files[@]}" 2>/dev/null | sed "s#^$REPO_ROOT/##" | tr '\n' ' ')"
        if [ -z "$hits" ]; then
            pass "T6 no $label"
        else
            fail "T6 $label found in: ${hits% }"
        fi
    }

    # Nine bytes encode to exactly twelve base64 characters with no padding, so the
    # marker matches the encoding of any PEM header regardless of what follows "BEGI".
    pem_b64_marker="$(printf -- '-----BEGI' | base64)"

    scan "AWS access key id"                 "-E"  'AKIA[0-9A-Z]{16}'
    scan "PEM private key header"            "-E"  'BEGIN [A-Z ]*PRIVATE KEY'
    scan "base64-encoded PEM header"         "-F"  "$pem_b64_marker"
    scan "GitHub token"                      "-E"  '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|github_pat_[A-Za-z0-9_]{22,}'
    scan "keyword-anchored AWS secret key"   "-Ei" '(secret_?access_?key)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+]{40}([^A-Za-z0-9/+]|$)'
fi
echo

# ---------------------------------------------------------------------------
echo "T7: fetch-aws-secrets.sh masks every fetched value in both parser branches"
path="$REPO_ROOT/.github/scripts/fetch-aws-secrets.sh"
if require_file T7 "$path"; then
    count="$(lf "$path" | grep -c '::add-mask::')"
    check "T7 fetch-aws-secrets.sh: '::add-mask::' appears exactly twice (python + jq)" 2 "$count"
fi
echo

# ---------------------------------------------------------------------------
echo "T8: .gitignore keeps local secret files out of git"
path="$REPO_ROOT/.gitignore"
if require_file T8 "$path"; then
    for line in '.env*' '*.pem' '*.key' '.secrets'; do
        if lf "$path" | grep -qxF -- "$line"; then
            pass "T8 .gitignore: has '$line'"
        else
            fail "T8 .gitignore: missing exact line '$line'"
        fi
    done
fi
echo

# ---------------------------------------------------------------------------
echo "T9: CODEOWNERS names only current SAH reviewers and covers the deploy paths"
path="$REPO_ROOT/.github/CODEOWNERS"
if require_file T9 "$path"; then
    owner_lines="$(lf "$path" | sed 's/#.*//' | grep -vE '^[[:space:]]*$')"
    owner_line_count="$(printf '%s\n' "$owner_lines" | grep -c .)"
    if [ "$owner_line_count" -ge 1 ]; then
        pass "T9 CODEOWNERS: $owner_line_count owner line(s)"
    else
        fail "T9 CODEOWNERS: no owner lines"
    fi
    unknown=""
    for token in $(printf '%s\n' "$owner_lines" | grep -oE '@[A-Za-z0-9-]+' | sort -u); do
        case " $ALLOWED_OWNERS " in
            *" $token "*) ;;
            *) unknown="$unknown $token" ;;
        esac
    done
    if [ -z "$unknown" ]; then
        pass "T9 CODEOWNERS: every owner is in {$ALLOWED_OWNERS}"
    else
        fail "T9 CODEOWNERS: owners outside {$ALLOWED_OWNERS}:${unknown}"
    fi
    for covered in '/.github/' '/docker/' '/scripts/' '/nginx/'; do
        escaped="$(printf '%s' "$covered" | sed 's/\./\\./g')"
        if printf '%s\n' "$owner_lines" | grep -qE "^${escaped}[[:space:]]"; then
            pass "T9 CODEOWNERS: covers $covered"
        else
            fail "T9 CODEOWNERS: no owner line for $covered"
        fi
    done
fi
echo

# ---------------------------------------------------------------------------
echo "T10: setup-aws-cli.sh does not print the caller identity on success"
path="$REPO_ROOT/.github/scripts/setup-aws-cli.sh"
if require_file T10 "$path"; then
    STUB_BIN="$(mktemp -d)"
    t10_out="$(mktemp)"
    trap 'rm -rf "$STUB_BIN" "$t10_out"' EXIT
    cat > "$STUB_BIN/aws" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    --version) echo "aws-cli/2.0.0 (stub)"; exit 0 ;;
    configure)
        case "$2" in
            set) exit 0 ;;
            get) echo "stub-value"; exit 0 ;;
        esac ;;
    sts) echo '{"UserId":"AIDAEXAMPLE","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/stub"}'; exit 0 ;;
esac
echo "stub aws: unexpected call: $*" >&2
exit 2
STUB
    chmod +x "$STUB_BIN/aws"
    PATH="$STUB_BIN:$PATH" bash "$path" dummy-access-key-id dummy-secret-access-key eu-west-2 > "$t10_out" 2>&1
    status=$?
    check "T10 setup-aws-cli.sh: exits 0 with a stub aws" 0 "$status"
    check "T10 setup-aws-cli.sh: output does not contain the stub AWS account id" 0 "$(grep -c '123456789012' "$t10_out")"
    check "T10 setup-aws-cli.sh: output does not contain an IAM ARN" 0 "$(grep -c 'arn:aws:iam' "$t10_out")"
    rm -rf "$STUB_BIN" "$t10_out"
fi
echo

# ---------------------------------------------------------------------------
echo "T11: generate-env-file.sh no longer writes the deploy-scope AWS keys to the box"
path="$REPO_ROOT/.github/scripts/generate-env-file.sh"
if require_file T11 "$path"; then
    block="$(lf "$path" | awk '
        /^REQUIRED_VARS=\(/ { inblock = 1; next }
        inblock && /^\)/ { inblock = 0 }
        inblock { print }
    ')"
    bucket_entries="$(printf '%s\n' "$block" | grep -c '"BUCKET_')"
    if [ "$bucket_entries" -ge 1 ]; then
        pass "T11 generate-env-file.sh: REQUIRED_VARS block extracted ($bucket_entries BUCKET_* entries kept)"
    else
        fail "T11 generate-env-file.sh: REQUIRED_VARS block not found or has no BUCKET_* entries (vacuous)"
    fi
    for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION; do
        count="$(printf '%s\n' "$block" | grep -cF "\"$var\"")"
        check "T11 generate-env-file.sh: REQUIRED_VARS lacks \"$var\"" 0 "$count"
    done
fi
echo

# ---------------------------------------------------------------------------
echo "T12: each deploy workflow picks its own sah_crm branch and it reaches the container"
# init.sh is promoted from staging to main unchanged, so a branch literal there would ship
# staging's sah_crm to production. The value must come from the environment's own workflow.
for pair in "deploy-prod.yml:main" "deploy-staging.yml:staging" "deploy-dev.yml:staging"; do
    wf="${pair%%:*}"; want="${pair##*:}"
    path="$WORKFLOW_DIR/$wf"
    require_file T12 "$path" || continue
    lines="$(lf "$path" | grep -E '^[[:space:]]*echo "SAH_CRM_BRANCH=' || true)"
    check "T12 $wf: writes SAH_CRM_BRANCH exactly once" 1 "$(printf '%s' "$lines" | grep -c 'SAH_CRM_BRANCH=')"
    check "T12 $wf: SAH_CRM_BRANCH is $want" "echo \"SAH_CRM_BRANCH=$want\" >> \"\${{ github.workspace }}/.env\"" "$(printf '%s' "$lines" | sed -E 's/^[[:space:]]+//')"
    # generate-env-file.sh truncates .env, and the next step ships it to the box, so the line only
    # counts if it runs after the generator and inside the same step.
    placement="$(lf "$path" | awk '
        /generate-env-file\.sh/ && !gen { gen = NR }
        gen && !next_step && NR > gen && /^[[:space:]]*- name:/ { next_step = NR }
        /echo "SAH_CRM_BRANCH=/ { echo_at = NR }
        END { print ((gen && echo_at > gen && (!next_step || echo_at < next_step)) ? "in-step" : "misplaced") }
    ')"
    check "T12 $wf: SAH_CRM_BRANCH is appended after generate-env-file.sh, in the same step" in-step "$placement"
done
path="$REPO_ROOT/docker/docker-compose.yml"
if require_file T12 "$path"; then
    check "T12 docker-compose.yml: passes SAH_CRM_BRANCH through, falling back to main" 1 \
        "$(lf "$path" | grep -cE '^[[:space:]]+- SAH_CRM_BRANCH=\$\{SAH_CRM_BRANCH:-main\}$')"
fi
path="$REPO_ROOT/docker/init.sh"
if require_file T12 "$path"; then
    check "T12 init.sh: SAH_CRM_BRANCH falls back to main, not a promoted staging literal" 1 \
        "$(lf "$path" | grep -cE '^SAH_CRM_BRANCH="\$\{SAH_CRM_BRANCH:-main\}"$')"
    check "T12 init.sh: nothing else assigns SAH_CRM_BRANCH" 1 \
        "$(lf "$path" | grep -cE '^[[:space:]]*(export[[:space:]]+)?SAH_CRM_BRANCH=')"
    # Without this the three checks above would pass against a clone that ignores the variable.
    check "T12 init.sh: the sah_crm clone uses \$SAH_CRM_BRANCH" 1 \
        "$(lf "$path" | grep -cE 'bench get-app "\$SAH_CRM_REPO" --branch "\$SAH_CRM_BRANCH"')"
fi
echo

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
