#!/usr/bin/env bash
#
# Tests for .github/scripts/check-public-tls.sh (run daily by erp-exposure-monitor.yml).
#
# `curl`, `openssl` and `nmap` are stubs selected through the CURL / OPENSSL / NMAP overrides
# the script exposes; each reads its canned answer from a scenario variable. Nothing here
# touches the network.
#
# Run:  bash .github/scripts/__tests__/check-public-tls.test.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$SCRIPT_DIR/../check-public-tls.sh}"
HOST=erp.example.com

passed=0
failed=0
pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
check() { # description, expected, actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# curl: `-w` (redirect probe) prints STUB_REDIRECT; `-I` (header probe) prints STUB_HEADERS.
cat > "$WORK/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        -w) printf '%s' "$STUB_REDIRECT"; exit 0 ;;
        -I) printf '%b' "$STUB_HEADERS"; exit 0 ;;
    esac
done
exit 1
STUB
# openssl: `x509` prints the notAfter line; `s_client` prints nothing (piped into x509).
cat > "$WORK/openssl" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "x509" ]; then cat > /dev/null; echo "notAfter=$STUB_NOT_AFTER"; fi
exit 0
STUB
cat > "$WORK/nmap" <<'STUB'
#!/usr/bin/env bash
printf '%b\n' "$STUB_NMAP"
STUB
chmod +x "$WORK/curl" "$WORK/openssl" "$WORK/nmap"

future_date() { # days from now, in openssl's notAfter format
    date -u -d "+$1 days" '+%b %e %T %Y GMT' 2>/dev/null || date -u -v "+$1d" '+%b %e %T %Y GMT'
}

GOOD_HEADERS='HTTP/2 200\r\nstrict-transport-security: max-age=63072000; includeSubDomains\r\n'
GOOD_NMAP='|   TLSv1.2:\n|   TLSv1.3:'

# Runs the script with the good baseline, overridden by any NAME=value arguments.
run() {
    env CURL="$WORK/curl" OPENSSL="$WORK/openssl" NMAP="$WORK/nmap" \
        STUB_REDIRECT="301 https://$HOST/login" \
        STUB_HEADERS="$GOOD_HEADERS" \
        STUB_NOT_AFTER="$(future_date 60)" \
        STUB_NMAP="$GOOD_NMAP" \
        "$@" bash "$SCRIPT_UNDER_TEST" "$HOST" 14 > "$WORK/out" 2>&1
    echo $?
}

echo "check-public-tls.sh"
check "all good -> exit 0" 0 "$(run)"
check "all good -> reports all checks passed" 1 "$(grep -c 'all TLS checks passed' "$WORK/out")"

check "no HSTS header -> exit 1" 1 "$(run STUB_HEADERS='HTTP/2 200\r\nserver: nginx\r\n')"
check "no HSTS header -> named in the output" 1 "$(grep -c 'no Strict-Transport-Security header' "$WORK/out")"

check "HSTS under one year -> exit 1" 1 "$(run STUB_HEADERS='HTTP/2 200\r\nStrict-Transport-Security: max-age=86400\r\n')"

check "HTTP not redirected -> exit 1" 1 "$(run STUB_REDIRECT='200 ')"
check "redirect to another host -> exit 1" 1 "$(run STUB_REDIRECT='301 https://evil.example/login')"

check "certificate inside 14 days -> exit 1" 1 "$(run STUB_NOT_AFTER="$(future_date 5)")"
check "certificate inside 14 days -> named in the output" 1 "$(grep -c 'renewal is failing' "$WORK/out")"

check "TLS 1.0 still accepted -> exit 1" 1 "$(run STUB_NMAP='|   TLSv1.0:\n|   TLSv1.2:')"
check "TLS 1.1 still accepted -> exit 1" 1 "$(run STUB_NMAP='|   TLSv1.1:\n|   TLSv1.2:')"
check "TLS 1.2 not offered -> exit 1" 1 "$(run STUB_NMAP='|   TLSv1.3:')"

check "missing nmap is a failure, not a skip" 1 "$(run NMAP="$WORK/does-not-exist")"

# Every breach is reported in one run, not only the first.
check "two breaches -> both reported" 2 \
    "$(run STUB_HEADERS='HTTP/2 200\r\n' STUB_NMAP='|   TLSv1.0:\n|   TLSv1.2:' > /dev/null; grep -c '^::error::' "$WORK/out")"

echo "-----------------------------------------"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ]
