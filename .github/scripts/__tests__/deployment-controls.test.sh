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
#   T15 (VC-657) configure-nginx workflows are not triggered by edits to their own file
#   T16 (VC-652) one rendered vhost for every environment: HTTP only redirects, HTTPS carries the
#       security headers; the certificate is ensured first, certbot never rewrites the vhost,
#       and configure-nginx.sh restores on a bad config and fails a run that does not serve HTTPS
#   T17 (VC-644) sites/<site> lives on the frappe-site-data volume and the encryption_key is a
#       required deploy secret; nothing removes the volume, and the first deploy with it copies
#       the running container's files in before `compose down` (never its random key)
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

# ---------------------------------------------------------------------------
echo "T16: the nginx vhost serves HTTPS with security headers, and a run cannot drop TLS"
# The 2026-09-24 prod outage: the workflow's inline template was HTTP-only, replaced the 443
# block certbot had added, and setup-certbot.sh skipped the host because a cert existed.
path="$REPO_ROOT/.github/scripts/render-nginx-conf.sh"
if require_file T16 "$path"; then
    t16_dir="$(mktemp -d)"
    trap 'rm -rf "$t16_dir"' EXIT
    conf="$t16_dir/nginx.conf"
    bash "$path" erp.example.com "$conf" > /dev/null 2>&1
    check "T16 render-nginx-conf.sh: renders for a hostname" 0 "$?"
    if [ -f "$conf" ]; then
        check "T16 vhost: exactly one listen 443 ssl" 1 "$(grep -cE '^[[:space:]]*listen[[:space:]]+443[[:space:]]+ssl' "$conf")"
        check "T16 vhost: certificate is read from live/<domain>/" 1 \
            "$(grep -cE '^[[:space:]]*ssl_certificate[[:space:]]+/etc/letsencrypt/live/erp\.example\.com/fullchain\.pem;' "$conf")"
        check "T16 vhost: key is read from live/<domain>/" 1 \
            "$(grep -cE '^[[:space:]]*ssl_certificate_key[[:space:]]+/etc/letsencrypt/live/erp\.example\.com/privkey\.pem;' "$conf")"
        check "T16 vhost: ssl_protocols is TLSv1.2 TLSv1.3 only" 1 \
            "$(grep -cE '^[[:space:]]*ssl_protocols[[:space:]]+TLSv1\.2[[:space:]]+TLSv1\.3;' "$conf")"
        # Per server block: its listen port, whether it redirects, whether it proxies.
        servers="$(awk '
            /^server[[:space:]]*\{/ { in_s = 1; depth = 0; port = ""; redir = 0; proxy = 0 }
            in_s {
                if (match($0, /listen[[:space:]]+[0-9]+/)) { split(substr($0, RSTART, RLENGTH), a, /[[:space:]]+/); port = a[2] }
                if ($0 ~ /return[[:space:]]+301[[:space:]]+https:\/\//) redir = 1
                if ($0 ~ /proxy_pass/) proxy = 1
                depth += gsub(/\{/, "{"); depth -= gsub(/\}/, "}")
                if (depth == 0) { printf "%s:%s:%s ", port, redir, proxy; in_s = 0 }
            }' "$conf")"
        check "T16 vhost: port 80 only redirects to https, port 443 proxies to Frappe" "80:1:0 443:0:1 " "$servers"
        # A block with its own add_header drops the inherited ones, so every block that sets
        # any header must set all four.
        missing="$(awk '
            { line = $0 }
            line ~ /\{/ { n++; stack[++sp] = n }
            line ~ /add_header/ { has[stack[sp]] = 1
                if (line ~ /Strict-Transport-Security "max-age=[0-9]+" always;/) h[stack[sp], 1] = 1
                if (line ~ /X-Content-Type-Options "nosniff" always;/) h[stack[sp], 2] = 1
                if (line ~ /X-Frame-Options "(SAMEORIGIN|DENY)" always;/) h[stack[sp], 3] = 1
                if (line ~ /Referrer-Policy "[a-z-]+" always;/) h[stack[sp], 4] = 1 }
            line ~ /\}/ { sp-- }
            END { blocks = 0; bad = 0
                for (b in has) { blocks++; for (i = 1; i <= 4; i++) if (!h[b, i]) bad++ }
                print blocks ":" bad }' "$conf")"
        check "T16 vhost: both header blocks (server, /assets) carry all four security headers" "2:0" "$missing"
    else
        fail "T16 render-nginx-conf.sh: produced no file"
    fi
    bash "$path" 'erp.example.com;include /etc/passwd' "$t16_dir/bad.conf" > /dev/null 2>&1
    check "T16 render-nginx-conf.sh: rejects a domain that is not a hostname" 1 "$?"
    check "T16 render-nginx-conf.sh: writes nothing for a rejected domain" no "$([ -e "$t16_dir/bad.conf" ] && echo yes || echo no)"
    rm -rf "$t16_dir"
fi
for env in prod staging dev; do
    path="$WORKFLOW_DIR/configure-nginx-$env.yml"
    require_file T16 "$path" || continue
    check "T16 configure-nginx-$env.yml: renders the vhost with render-nginx-conf.sh" 1 \
        "$(lf "$path" | grep -c '\.github/scripts/render-nginx-conf\.sh')"
    check "T16 configure-nginx-$env.yml: carries no inline vhost" 0 "$(lf "$path" | grep -cE 'listen[[:space:]]+[0-9]+')"
    order="$(lf "$path" | awk '
        /- name: Setup SSL certificate/ && !c { c = NR }
        /- name: Configure Nginx$/ && !n { n = NR }
        END { print ((c && n && c < n) ? "cert-first" : "wrong:" c "," n) }')"
    check "T16 configure-nginx-$env.yml: the certificate is ensured before the vhost is installed" cert-first "$order"
done
path="$REPO_ROOT/.github/scripts/setup-certbot.sh"
if require_file T16 "$path"; then
    check "T16 setup-certbot.sh: never lets certbot rewrite the vhost (no 'certbot --nginx')" 0 \
        "$(lf "$path" | grep -cE 'certbot[[:space:]]+--nginx')"
    check "T16 setup-certbot.sh: issues with 'certbot certonly --nginx' (non-vacuous)" 1 \
        "$(lf "$path" | grep -cE 'certbot[[:space:]]+certonly[[:space:]]+--nginx')"
    check "T16 setup-certbot.sh: pins --cert-name to the domain" 1 "$(lf "$path" | grep -cE -- '--cert-name[[:space:]]+\$CERTBOT_DOMAIN')"
    check "T16 setup-certbot.sh: reloads nginx after renewal" 1 "$(lf "$path" | grep -cE -- '--deploy-hook "systemctl reload nginx"')"
    check "T16 setup-certbot.sh: an existing cert must be at live/<domain>/" 1 \
        "$(lf "$path" | grep -cF 'test -f /etc/letsencrypt/live/$CERTBOT_DOMAIN/fullchain.pem')"
fi
path="$REPO_ROOT/.github/scripts/configure-nginx.sh"
if require_file T16 "$path"; then
    # shellcheck disable=SC2016
    check "T16 configure-nginx.sh: restores the previous vhost when nginx -t fails" 1 \
        "$(lf "$path" | grep -cF 'sudo mv -f "\$VHOST.previous" "\$VHOST"')"
    # shellcheck disable=SC2016
    check "T16 configure-nginx.sh: checks HTTPS on the host after reload" 1 \
        "$(lf "$path" | grep -cF -- '--resolve "$CERTBOT_DOMAIN:443:127.0.0.1"')"
    # shellcheck disable=SC2016
    check "T16 configure-nginx.sh: fails unless HTTP redirects (301)" 1 "$(lf "$path" | grep -cF 'if [ "\$http_code" != "301" ]')"
fi
echo

echo "T17: site data and the encryption key survive a deploy"
# Every deploy runs `compose down && up`. The bench, including sites/<site>, lived inside the
# container, so each deploy discarded uploaded files and site_config.json -- whose rebuilt
# copy had no encryption_key, so Frappe generated a random one and every stored secret became
# undecryptable (prod: "Failed to decrypt key ...otpsecret").
compose="$REPO_ROOT/docker/docker-compose.yml"
if require_file T17 "$compose"; then
    check "T17 compose: frappe-site-data is a declared named volume" 1 "$(lf "$compose" | grep -cE '^  frappe-site-data:[[:space:]]*$')"
    check "T17 compose: frappe mounts it at /home/frappe/site-data" 1 \
        "$(lf "$compose" | grep -cE '^[[:space:]]+- frappe-site-data:/home/frappe/site-data[[:space:]]*$')"
    # A mount inside the bench creates $BENCH_DIR before `bench init`, which init.sh then skips.
    check "T17 compose: no mount inside /home/frappe/frappe-bench" 0 "$(lf "$compose" | grep -cE ':/home/frappe/frappe-bench')"
    check "T17 compose: ENCRYPTION_KEY comes from FRAPPE_ENCRYPTION_KEY and is required" 1 \
        "$(lf "$compose" | grep -cF -- '- ENCRYPTION_KEY=${FRAPPE_ENCRYPTION_KEY:?')"
fi
path="$REPO_ROOT/.github/scripts/generate-env-file.sh"
if require_file T17 "$path"; then
    check "T17 generate-env-file.sh: FRAPPE_ENCRYPTION_KEY is a REQUIRED variable" 1 \
        "$(lf "$path" | sed -n '/^REQUIRED_VARS=(/,/^)/p' | grep -cxF '    "FRAPPE_ENCRYPTION_KEY"')"
fi
destroyers="$(grep -rnE 'down[[:space:]]+(-v|--volumes)|volume[[:space:]]+(rm|prune)|system[[:space:]]+prune' \
    "$REPO_ROOT/.github" "$REPO_ROOT/docker" "$REPO_ROOT/scripts" 2>/dev/null | grep -v '__tests__' | wc -l | tr -d ' ')"
check "T17 nothing under .github/, docker/ or scripts/ removes a volume" 0 "$destroyers"
path="$REPO_ROOT/.github/scripts/deploy-docker-app.sh"
if require_file T17 "$path"; then
    seed_line="$(lf "$path" | grep -n 'remote/seed-site-volume.sh' | head -1 | cut -d: -f1)"
    down_line="$(lf "$path" | grep -n 'docker compose .* down' | head -1 | cut -d: -f1)"
    if [ -n "$seed_line" ] && [ -n "$down_line" ] && [ "$seed_line" -lt "$down_line" ]; then
        pass "T17 deploy-docker-app.sh: seeds the volume before compose down"
    else
        fail "T17 deploy-docker-app.sh: seed ($seed_line) does not run before compose down ($down_line)"
    fi
fi
seed="$REPO_ROOT/.github/scripts/remote/seed-site-volume.sh"
if require_file T17 "$seed"; then
    check "T17 seed-site-volume.sh: never copies site_config.json (its key is the random one)" 0 \
        "$(lf "$seed" | grep -v '^[[:space:]]*#' | grep -c 'site_config')"
    t17_dir="$(mktemp -d)"
    mkdir -p "$t17_dir/bin" "$t17_dir/deploy"
    printf 'SITE_NAME="erp.example.com"\nDB_PASSWORD=x\n' > "$t17_dir/deploy/.env"
    cat > "$t17_dir/bin/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    cat > "$t17_dir/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$T17_LOG"
case "$*" in
    *" ps -q frappe"*) [ -n "${NO_CONTAINER:-}" ] || echo cid123 ;;
    "exec cid123 test -L "*) [ -n "${LINKED:-}" ] ;;
    "exec cid123 test -d "*) exit 0 ;;
    "cp cid123:"*) echo "TAR ${2##*/}" ;;
    *" run "*"test -e "*) [ -n "${VOLUME_HAS_SITE:-}" ] ;;
    *" run "*"tar -x"*) cat >> "$T17_LOG.tar" ;;
    *" run "*"wc -l"*) echo " 3" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$t17_dir/bin/sudo" "$t17_dir/bin/docker"
    run_seed() { # $1 = scenario name; env from the caller
        : > "$t17_dir/$1.log"
        T17_LOG="$t17_dir/$1.log" PATH="$t17_dir/bin:$PATH" \
            bash "$seed" "$t17_dir/deploy" docker/docker-compose.yml > "$t17_dir/$1.out" 2>&1
        echo $?
    }
    check "T17 seed: first deploy exits 0" 0 "$(run_seed fresh)"
    check "T17 seed: copies public/ and private/ out of the container" 2 "$(grep -cE '^cp cid123:/home/frappe/frappe-bench/sites/erp\.example\.com/(public|private) -$' "$t17_dir/fresh.log")"
    check "T17 seed: both streams reach the volume" "TAR public TAR private" "$(tr '\n' ' ' < "$t17_dir/fresh.log.tar" | sed 's/ $//')"
    check "T17 seed: hands the volume to uid 1000" 1 "$(grep -c 'chown -R 1000:1000 /home/frappe/site-data' "$t17_dir/fresh.log")"
    check "T17 seed: reports the count only" 1 "$(grep -c 'Seeded the volume with 3 file(s)' "$t17_dir/fresh.out")"
    check "T17 seed: runs with the deploy env file" 0 "$(grep ' run ' "$t17_dir/fresh.log" | grep -vc -- "--env-file $t17_dir/deploy/.env")"
    check "T17 seed: no running container -> exits 0, copies nothing" "0 0" "$(NO_CONTAINER=1 run_seed none) $(grep -c '^cp ' "$t17_dir/none.log")"
    check "T17 seed: container already on the volume -> copies nothing" "0 0" "$(LINKED=1 run_seed linked) $(grep -c '^cp ' "$t17_dir/linked.log")"
    check "T17 seed: volume already holds the site -> never overwritten" "0 0" "$(VOLUME_HAS_SITE=1 run_seed full) $(grep -c '^cp ' "$t17_dir/full.log")"
    rm -rf "$t17_dir"
fi
echo

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
