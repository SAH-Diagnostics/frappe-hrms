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
#   T13 (VC-657) the on-box .env is moved, not copied, and created owner-only; no container log
#       is printed into the public deploy log (verify-site.sh saves it to a root-only file)
#   T14 (VC-657) secret-scan.yml runs a pinned, checksum-verified gitleaks with --redact, holds
#       no secrets, uses no gitleaks-action and passes no ${{ }} expression into a run: script
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
# Its own list, NOT $SAH_WORKFLOWS: it is not a deploy workflow, holds no environment and no
# secrets, so T2/T5/T12 do not apply to it.
SECRET_SCAN_WORKFLOW="secret-scan.yml"

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
for wf in $SAH_WORKFLOWS $SECRET_SCAN_WORKFLOW; do
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
for wf in $SAH_WORKFLOWS $SECRET_SCAN_WORKFLOW; do
    path="$WORKFLOW_DIR/$wf"
    require_file T3 "$path" || continue
    count="$(lf "$path" | grep -c GITHUB_ENV)"
    check "T3 $wf: no GITHUB_ENV" 0 "$count"
done
echo

# ---------------------------------------------------------------------------
echo "T4: every action is pinned to a full commit SHA with a version comment"
PIN_RE='^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]+(\.[0-9]+){0,2}[[:space:]]*$'
for wf in $SAH_WORKFLOWS $CONTROLS_WORKFLOW $SECRET_SCAN_WORKFLOW; do
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

# ---------------------------------------------------------------------------
echo "T13: the on-box .env is moved and owner-only, and no container log reaches the deploy log"
# SC2016 (T13/T14): the single-quoted patterns match literal script text such as
# $ENV_FILE_SOURCE and ${{ }}; they are not meant to expand. Scoped to the next command only,
# so each literal-pattern line below carries its own directive.
# The deploy log is public. A copied .env left every secret in the upload path (the user's
# home); a group/world-readable .env exposed it to every account on the box; and container
# logs (bench, init.sh) can carry credentials.
path="$REPO_ROOT/.github/scripts/deploy-docker-app.sh"
if require_file T13 "$path"; then
    # shellcheck disable=SC2016
    check "T13 deploy-docker-app.sh: moves the env file into place (mv -f)" 1 \
        "$(lf "$path" | grep -cE '^[[:space:]]*mv -f \$ENV_FILE_SOURCE \$DEPLOY_DIR/\.env[[:space:]]*$')"
    check "T13 deploy-docker-app.sh: never copies the env file (no 'cp \$ENV_FILE_SOURCE')" 0 \
        "$(lf "$path" | grep -cE '(^|[[:space:]])cp[[:space:]].*\$\{?ENV_FILE_SOURCE')"
    order="$(lf "$path" | awk '
        /^[[:space:]]*umask 077[[:space:]]*$/ && !u { u = NR }
        /^[[:space:]]*mv -f \$ENV_FILE_SOURCE / && !m { m = NR }
        /^[[:space:]]*chmod 600 \$DEPLOY_DIR\/\.env[[:space:]]*$/ && !c { c = NR }
        END { print ((u && m && c && u < m && m < c) ? "umask-mv-chmod" : "wrong:" u "," m "," c) }
    ')"
    check "T13 deploy-docker-app.sh: umask 077, then mv -f, then chmod 600" umask-mv-chmod "$order"
    check "T13 deploy-docker-app.sh: runs no 'docker compose ... logs'" 0 \
        "$(lf "$path" | grep -vE '^[[:space:]]*(#|echo )' | grep -cE 'docker[[:space:]]+compose.*[[:space:]]logs([[:space:]]|$)')"
fi
path="$REPO_ROOT/.github/scripts/remote/verify-site.sh"
if require_file T13 "$path"; then
    logs_lines="$(lf "$path" | grep -vE '^[[:space:]]*(#|echo )' | grep -cE 'docker[[:space:]]+compose.*[[:space:]]logs([[:space:]]|$)')"
    check "T13 verify-site.sh: exactly one 'docker compose ... logs' call (non-vacuous)" 1 "$logs_lines"
    # That call must sit in the { ... } group whose output is piped to the root-only file and
    # nowhere else: the group's closing line must tee to \$FAILURE_LOG and discard stdout.
    sink="$(lf "$path" | awk '
        /^[[:space:]]*(#|echo )/ { next }
        /docker[[:space:]]+compose.*[[:space:]]logs([[:space:]]|$)/ { seen = 1; next }
        seen && /^[[:space:]]*}/ { print; exit }
    ')"
    # shellcheck disable=SC2016
    case "$sink" in
        *'| sudo tee "$FAILURE_LOG" >/dev/null'*) pass "T13 verify-site.sh: container logs are piped only to \$FAILURE_LOG" ;;
        *) fail "T13 verify-site.sh: container logs are not confined to \$FAILURE_LOG (group closes with: '$sink')" ;;
    esac
    check "T13 verify-site.sh: failure log defaults to /var/log/erp-deploy" 1 \
        "$(lf "$path" | grep -cE '^FAILURE_LOG_DIR="\$\{FAILURE_LOG_DIR:-/var/log/erp-deploy\}"$')"
    # shellcheck disable=SC2016
    check "T13 verify-site.sh: failure-log dir is created 0700" 1 \
        "$(lf "$path" | grep -cF 'sudo install -d -m 700 "$FAILURE_LOG_DIR"')"
fi
path="$REPO_ROOT/.github/scripts/generate-env-file.sh"
if require_file T13 "$path"; then
    order="$(lf "$path" | awk '
        /^[[:space:]]*umask 077[[:space:]]*$/ && !u { u = NR }
        /^[[:space:]]*>[[:space:]]*"\$OUTPUT_ENV_FILE"[[:space:]]*$/ && !t { t = NR }
        END { print ((u && t && u < t) ? "umask-first" : "wrong:" u "," t) }
    ')"
    check "T13 generate-env-file.sh: umask 077 is set before the env file is truncated" umask-first "$order"
fi
echo

# ---------------------------------------------------------------------------
echo "T14: secret-scan.yml runs a pinned, verified gitleaks with --redact and holds no secrets"
path="$WORKFLOW_DIR/$SECRET_SCAN_WORKFLOW"
if require_file T14 "$path"; then
    calls="$(lf "$path" | grep -vE '^[[:space:]]*#' | grep -E '(^|[[:space:]])gitleaks[[:space:]]+(git|dir|detect|protect|stdin)([[:space:]]|$)')"
    n_calls="$(printf '%s' "$calls" | grep -c .)"
    n_redacted="$(printf '%s' "$calls" | grep -c -- '--redact')"
    if [ "$n_calls" -ge 1 ] && [ "$n_calls" = "$n_redacted" ]; then
        pass "T14 secret-scan.yml: all $n_calls gitleaks scan call(s) pass --redact"
    else
        fail "T14 secret-scan.yml: gitleaks scan calls=$n_calls, with --redact=$n_redacted (must be equal and >= 1)"
    fi
    check "T14 secret-scan.yml: does not use gitleaks-action" 0 \
        "$(lf "$path" | grep -vE '^[[:space:]]*#' | grep -ciE 'gitleaks-action|uses:[^#]*gitleaks')"
    check "T14 secret-scan.yml: references no secrets" 0 "$(lf "$path" | grep -c 'secrets\.')"
    check "T14 secret-scan.yml: uploads no report artifact" 0 "$(lf "$path" | grep -c 'upload-artifact')"
    check "T14 secret-scan.yml: verifies the gitleaks download with sha256sum -c" 1 \
        "$(lf "$path" | grep -cE 'sha256sum -c')"
    check "T14 secret-scan.yml: pins a 64-hex gitleaks sha256" 1 \
        "$(lf "$path" | grep -cE '^[[:space:]]+GITLEAKS_SHA256:[[:space:]]+[0-9a-f]{64}[[:space:]]*$')"
    check "T14 secret-scan.yml: checkout is SHA-pinned (v4.4.0)" 1 \
        "$(lf "$path" | grep -cE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+actions/checkout@11d5960a326750d5838078e36cf38b85af677262[[:space:]]+#[[:space:]]*v4\.4\.0[[:space:]]*$')"
    check "T14 secret-scan.yml: checkout fetches full history (fetch-depth: 0)" 1 \
        "$(lf "$path" | grep -cE '^[[:space:]]+fetch-depth:[[:space:]]*0[[:space:]]*$')"
    # Event fields reach the script through env:, never as ${{ }} spliced into run: text,
    # where a crafted ref or title would be executed.
    # shellcheck disable=SC2016
    stray="$(lf "$path" | grep -F '${{' | grep -vcE '^[[:space:]]+[A-Z_]+:[[:space:]]+\$\{\{[^}]*\}\}[[:space:]]*$')"
    check "T14 secret-scan.yml: every \${{ }} expression is an env: mapping, none inside run:" 0 "$stray"
fi
echo

# ---------------------------------------------------------------------------
echo "T15: configure-nginx workflows are not triggered by edits to their own file"
# configure-nginx.sh rewrites the vhost as HTTP-only and setup-certbot.sh skips a host that
# already has a certificate, so an unintended run drops TLS. Listing the workflow's own path
# under `paths:` meant any edit to the workflow -- including a staging -> main promotion that
# touches it -- ran it against that environment. Only nginx/** (or a manual run) may.
for env in prod staging dev; do
    path="$WORKFLOW_DIR/configure-nginx-$env.yml"
    if require_file T15 "$path"; then
        check "T15 configure-nginx-$env.yml: does not list its own path as a push trigger" 0 \
            "$(lf "$path" | grep -cE "^[[:space:]]*-[[:space:]]*'?\.github/workflows/configure-nginx-$env\.yml'?[[:space:]]*$")"
        check "T15 configure-nginx-$env.yml: still triggers on nginx/** (non-vacuous)" 1 \
            "$(lf "$path" | grep -cE "^[[:space:]]*-[[:space:]]*'nginx/\*\*'[[:space:]]*$")"
    fi
done
echo

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
