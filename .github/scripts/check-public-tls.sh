#!/usr/bin/env bash
#
# External HTTPS check for an ERP hostname, run from a GitHub runner (erp-exposure-monitor.yml).
# Ported from the Virtual Clinics (medplum) check of the same name, so both estates are held
# to the same public-endpoint baseline.
#
#   check-public-tls.sh <hostname> [min-days]
#
# Asserts, from outside the host:
#   - plain HTTP answers with a 301 to https://<hostname>/...
#   - HTTPS sends Strict-Transport-Security with max-age >= 1 year
#   - the served certificate is valid for at least <min-days> more days (default 14;
#     Let's Encrypt renews at 30, so less than 14 means renewal has failed for two weeks)
#   - TLS 1.2 is offered and TLS 1.0 / 1.1 / SSLv3 are not
#
# Protocol support is read with nmap's ssl-enum-ciphers, which speaks TLS through its own
# implementation: the runner's OpenSSL refuses to offer TLS 1.0/1.1 at its default security
# level, so 'openssl s_client -tls1' would pass a server that still accepts them.
#
# Every failure is collected and reported; the script exits 1 if there was any. A missing
# tool is a failure, never a skipped check. CURL, OPENSSL and NMAP may be overridden (tests).

set -uo pipefail

CURL=${CURL:-curl}
OPENSSL=${OPENSSL:-openssl}
NMAP=${NMAP:-nmap}

HSTS_MIN_AGE=31536000
# Frappe serves the login page to an anonymous request; it is the cheapest page that goes
# through nginx to the application.
PROBE_PATH=/login

failures=()

fail() {
  failures+=("$1")
  echo "::error::$1"
}

ok() {
  echo "  ok   $1"
}

check_redirect() {
  local host=$1 out code location
  if ! out=$($CURL -sS -o /dev/null --max-time 15 -w '%{http_code} %{redirect_url}' "http://${host}${PROBE_PATH}" 2>&1); then
    fail "${host}: plain HTTP request failed: ${out}"
    return
  fi
  code=${out%% *}
  location=${out#* }
  if [ "$code" != "301" ]; then
    fail "${host}: plain HTTP returned ${code}, expected 301"
  elif [[ "$location" != "https://${host}/"* ]]; then
    fail "${host}: plain HTTP redirects to '${location}', expected https://${host}/..."
  else
    ok "${host}: HTTP 301 -> HTTPS"
  fi
}

# Prints the max-age from a Strict-Transport-Security header block, or nothing.
hsts_max_age() {
  tr -d '\r' | grep -i '^strict-transport-security:' | head -1 \
    | grep -oiE 'max-age=[0-9]+' | cut -d= -f2
}

check_hsts() {
  local host=$1 headers age
  if ! headers=$($CURL -sS -I --max-time 15 "https://${host}${PROBE_PATH}" 2>&1); then
    fail "${host}: HTTPS request failed: ${headers}"
    return
  fi
  age=$(printf '%s\n' "$headers" | hsts_max_age)
  if [ -z "$age" ]; then
    fail "${host}: no Strict-Transport-Security header on HTTPS"
  elif [ "$age" -lt "$HSTS_MIN_AGE" ]; then
    fail "${host}: HSTS max-age ${age} is below ${HSTS_MIN_AGE}"
  else
    ok "${host}: HSTS max-age=${age}"
  fi
}

# Days from now until a 'notAfter=...' date, as printed by 'openssl x509 -enddate'.
days_until() {
  local end=$1 end_epoch now
  if ! end_epoch=$(date -u -d "$end" +%s 2>/dev/null); then
    end_epoch=$(date -u -j -f '%b %e %T %Y %Z' "$end" +%s 2>/dev/null) || return 1
  fi
  now=$(date -u +%s)
  echo $(( (end_epoch - now) / 86400 ))
}

check_expiry() {
  local host=$1 min_days=$2 enddate days
  enddate=$($OPENSSL s_client -connect "${host}:443" -servername "$host" </dev/null 2>/dev/null \
    | $OPENSSL x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -z "$enddate" ]; then
    fail "${host}: could not read the served certificate"
    return
  fi
  if ! days=$(days_until "$enddate"); then
    fail "${host}: could not parse certificate expiry '${enddate}'"
  elif [ "$days" -lt "$min_days" ]; then
    fail "${host}: certificate expires in ${days} days (${enddate}); minimum is ${min_days} -- renewal is failing"
  else
    ok "${host}: certificate valid for ${days} more days"
  fi
}

check_protocols() {
  local host=$1 scan
  if ! command -v "$NMAP" >/dev/null 2>&1; then
    fail "${host}: nmap is not installed, so TLS protocol support cannot be checked"
    return
  fi
  if ! scan=$($NMAP -Pn -p 443 --script ssl-enum-ciphers "$host" 2>&1); then
    fail "${host}: nmap ssl-enum-ciphers failed: ${scan}"
    return
  fi
  if ! grep -q 'TLSv1\.2:' <<<"$scan"; then
    fail "${host}: TLS 1.2 is not offered"
  fi
  if grep -qE 'TLSv1\.[01]:|SSLv3:' <<<"$scan"; then
    fail "${host}: a protocol older than TLS 1.2 is still accepted"
  fi
  if grep -q 'TLSv1\.2:' <<<"$scan" && ! grep -qE 'TLSv1\.[01]:|SSLv3:' <<<"$scan"; then
    ok "${host}: TLS 1.2+ only"
  fi
}

main() {
  if [ $# -lt 1 ] || [ -z "$1" ]; then
    echo "Usage: $0 <hostname> [min-days]" >&2
    exit 2
  fi
  local host=$1 min_days=${2:-14}
  # A non-number would make the expiry comparison error out and fall through to "valid".
  case "$min_days" in
    '' | *[!0-9]*)
      echo "::error::min-days must be a whole number, got '${min_days}'" >&2
      exit 2 ;;
  esac

  echo "Checking public TLS for ${host} (certificate minimum ${min_days} days)"
  check_redirect "$host"
  check_hsts "$host"
  check_expiry "$host" "$min_days"
  check_protocols "$host"

  if [ ${#failures[@]} -gt 0 ]; then
    echo "${host}: ${#failures[@]} TLS check(s) failed"
    exit 1
  fi
  echo "${host}: all TLS checks passed"
}

main "$@"
