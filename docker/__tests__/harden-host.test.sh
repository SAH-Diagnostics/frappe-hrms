#!/usr/bin/env bash
# SC2016: the bash -c bodies are single-quoted on purpose ($1 is their own argument).
# SC2001/SC2034/SC2329/SC1091: sed on fixtures, stub variables read via ${!v}, an id()
# stub called by the sourced script, and a source path resolved at run time.
# shellcheck disable=SC2016,SC2001,SC2034,SC2329,SC1091
#
# Tests for docker/host/harden-host.sh (production ERP host hardening).
#
# Why this file exists
# --------------------
# The script changes sshd and the host firewall on a production box reachable only over
# SSH. A wrong AllowGroups, a ruleset that flushes ufw's/Docker's tables, or a rollback that
# does not undo what apply did would lock CI (and people) out, or silently cut container
# egress. These checks pin the properties that matter.
#
# Two layers:
#   unit       (default; runs anywhere, in CI) - sources the script with main disabled and
#              exercises the renderers and parsers with stubbed commands.
#   container  (bash harden-host.test.sh --container; needs Docker) - runs the real
#              --apply / --verify / --disarm / --rollback in a privileged, network-isolated
#              ubuntu:22.04 container with real sshd -t / sshd -T, real nft, real apt-config
#              and iptables-nft. systemd is not running there, so systemctl and systemd-run
#              are recorded by stubs and the dead-man is "fired" by running what was armed.
#
# Run:  bash docker/__tests__/harden-host.test.sh [--container]
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARDEN="${HARDEN:-$SCRIPT_DIR/../host/harden-host.sh}"
[ -f "$HARDEN" ] || {
  echo "FATAL: cannot find harden-host.sh at $HARDEN" >&2
  exit 1
}

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  echo "  ok   - $1"
}
not_ok() {
  FAIL=$((FAIL + 1))
  echo "  FAIL - $1"
}
check() { # check <description> <command...>
  local d=$1
  shift
  if "$@"; then ok "$d"; else not_ok "$d"; fi
}

run_unit() {
  echo "# unit"
  # shellcheck source=../host/harden-host.sh
  HARDEN_HOST_NO_MAIN=1 source "$HARDEN"
  set +e +u

  local nft sshd apt
  nft=$(render_nft_ruleset)
  check "nft ruleset never flushes the whole ruleset" bash -c '! grep -q "flush ruleset" <<<"$1"' _ "$nft"
  check "nft ruleset is idempotent (table / delete table / table)" \
    bash -c '[ "$(grep -c "^table inet sah_host_fw" <<<"$1")" = 2 ] && grep -q "^delete table inet sah_host_fw$" <<<"$1"' _ "$nft"
  check "nft input policy is drop" grep -q 'hook input priority filter; policy drop;' <<<"$nft"
  check "nft allows only 22/80/443 by port" grep -q 'tcp dport { 22, 80, 443 } accept' <<<"$nft"
  local icmp6 dhcp invalid
  icmp6=$(grep -n 'ipv6-icmp accept' <<<"$nft" | cut -d: -f1)
  dhcp=$(grep -n 'udp dport 68 accept' <<<"$nft" | cut -d: -f1)
  invalid=$(grep -n 'ct state invalid drop' <<<"$nft" | cut -d: -f1)
  check "ICMPv6 and DHCP accepts come before the invalid-drop" bash -c '[ "$1" -lt "$3" ] && [ "$2" -lt "$3" ]' _ "$icmp6" "$dhcp" "$invalid"
  check "docker bridges accepted" bash -c 'grep -q "iifname \"docker0\" accept" <<<"$1" && grep -q "iifname \"br-\*\" accept" <<<"$1"' _ "$nft"
  check "script never uses the distro nftables unit" bash -c '! grep -E "systemctl +(enable|disable|start|restart|reload|stop|mask)( +--now)? +nftables" "$1"' _ "$HARDEN"
  check "script never touches ufw state" bash -c '! grep -E "ufw (enable|disable|allow|deny|default|reset|reload)" "$1"' _ "$HARDEN"

  sshd=$(render_sshd_dropin)
  for kv in "PermitRootLogin no" "PasswordAuthentication no" "KbdInteractiveAuthentication no" "AllowGroups sudo"; do
    check "sshd drop-in sets '$kv'" grep -qx "$kv" <<<"$sshd"
  done
  check "sshd drop-in does not use AllowUsers (would AND with AllowGroups)" bash -c '! grep -qi "^AllowUsers" <<<"$1"' _ "$sshd"
  check "sshd drop-in sorts before 60-cloudimg and 99-vc651" [ "$(basename "$SSHD_DROPIN")" = "01-sah-hardening.conf" ]

  local good='permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
x11forwarding no
allowgroups sudo'
  check "sshd_effective_missing: hardened config passes" [ -z "$(sshd_effective_missing <<<"$good")" ]
  check "sshd_effective_missing: root login flagged" grep -q permitrootlogin <<<"$(sed 's/permitrootlogin no/permitrootlogin prohibit-password/' <<<"$good" | sshd_effective_missing)"
  check "sshd_effective_missing: extra group flagged" grep -q allowgroups <<<"$(sed 's/allowgroups sudo/allowgroups sudo admin/' <<<"$good" | sshd_effective_missing)"
  check "sshd_effective_missing: AllowUsers flagged" grep -q allowusers <<<"$(printf '%s\nallowusers ubuntu\n' "$good" | sshd_effective_missing)"

  apt=$(render_apt_conf)
  check "apt conf clears the distro origin list before setting it" grep -qx '#clear Unattended-Upgrade::Allowed-Origins;' <<<"$apt"
  check "apt conf origins are all -security" bash -c '! sed -n "/Allowed-Origins {/,/};/p" <<<"$1" | grep "\"" | grep -qv -- "-security"' _ "$apt"
  check "apt conf never reboots" grep -qx 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$apt"
  check "apt conf keeps \${distro_id} literal" grep -q '"${distro_id}:${distro_codename}-security"' <<<"$apt"

  local rb
  rb=$(render_rollback_script)
  check "rollback deletes only our table" grep -q 'nft delete table inet sah_host_fw' <<<"$rb"
  check "rollback removes the drop-in and reloads ssh after sshd -t" bash -c 'grep -q "rm -f /etc/ssh/sshd_config.d/01-sah-hardening.conf" <<<"$1" && grep -q "systemctl reload ssh" <<<"$1"' _ "$rb"
  check "rollback leaves the user_data 99-vc651 drop-in alone" bash -c '! grep -q 99-vc651 <<<"$1"' _ "$rb"
  check "fw unit never loads /etc/nftables.conf" bash -c '! grep -q "ExecStart=.*/etc/nftables.conf" <<<"$1"' _ "$(render_fw_unit)"

  local ports='frappe 127.0.0.1:8000->8000/tcp, 127.0.0.1:9000->9000/tcp
redis 6379/tcp
web 0.0.0.0:8080->80/tcp, :::8080->80/tcp'
  local bad
  bad=$(non_loopback_ports <<<"$ports")
  check "loopback-bound ports pass, unpublished ports ignored" bash -c '! grep -q "frappe\|redis" <<<"$1"' _ "$bad"
  check "0.0.0.0 and :: publications flagged" [ "$(wc -l <<<"$bad" | tr -d ' ')" = 2 ]

  local sim='Inst libssl3 [3.0.2-0ubuntu1.15] (3.0.2-0ubuntu1.18 Ubuntu:22.04/jammy-updates, Ubuntu:22.04/jammy-security [amd64])
Inst tzdata [2024a-0ubuntu0.22.04] (2025b-0ubuntu0.22.04 Ubuntu:22.04/jammy-updates [all])
Conf libssl3 (3.0.2-0ubuntu1.18 Ubuntu:22.04/jammy-updates, Ubuntu:22.04/jammy-security [amd64])'
  check "pending_security_pkgs counts only -security Inst lines" [ "$(pending_security_pkgs <<<"$sim")" = "libssl3" ]
  # Public repo: by default the summary carries a count, never package names.
  local quiet loud
  quiet=$(summarise_pending "$(printf 'libssl3\nopenssh-server')")
  loud=$(HARDEN_VERBOSE=1 summarise_pending "$(printf 'libssl3\nopenssh-server')")
  check "pending summary reports the count" grep -q '2 security update(s) pending' <<<"$quiet"
  check "pending summary names no package by default" bash -c '! grep -q "libssl3\|openssh" <<<"$1"' _ "$quiet"
  check "HARDEN_VERBOSE=1 adds the package names" grep -q 'libssl3 openssh-server' <<<"$loud"
  check "no pending updates reads 'none'" [ "$(summarise_pending '')" = "pending security updates: none" ]
  check "verify prints the kernel only through detail()" bash -c '! grep -nE "^[[:space:]]*echo .*uname -r" "$1"' _ "$HARDEN"

  # The dispatch workflow: same supply-chain and credential rules as the deploy workflows.
  local wf="$SCRIPT_DIR/../../.github/workflows/harden-lightsail-host.yml"
  local uses pinned
  uses=$(grep -cE '^[[:space:]]*-?[[:space:]]*uses:' "$wf")
  pinned=$(grep -cE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]' "$wf")
  check "workflow: every action pinned to a commit SHA ($pinned/$uses)" bash -c '[ "$1" -ge 1 ] && [ "$1" = "$2" ]' _ "$uses" "$pinned"
  check "workflow: assumes the OIDC role" grep -qE '^[[:space:]]+role-to-assume:[[:space:]]+arn:aws:iam::[0-9]{12}:role/github-actions-prod-erp-role$' "$wf"
  check "workflow: no static AWS key pair" bash -c '! grep -qE "AWS_ACCESS_KEY_ID|AWS_SECRETS_ACCESS_KEY|setup-aws-cli" "$1"' _ "$wf"

  # access_problems with a stubbed id/group database.
  local tmp
  tmp=$(mktemp -d)
  MARKER_DIR="$tmp/markers" HOME_ROOT="$tmp/home"
  mkdir -p "$MARKER_DIR" "$HOME_ROOT/alice/.ssh"
  echo "ssh-ed25519 AAAA" >"$HOME_ROOT/alice/.ssh/authorized_keys"
  touch "$MARKER_DIR/alice"
  STUB_GROUPS_ubuntu="ubuntu adm sudo" STUB_GROUPS_alice="alice sudo docker"
  id() {
    local u=${*: -1} v
    v="STUB_GROUPS_$u"
    [ -n "${!v:-}" ] || return 1
    case "$1" in -nG) echo "${!v}" ;; esac
  }
  check "access_problems: ubuntu + admins in sudo -> safe" [ -z "$(access_problems)" ]
  STUB_GROUPS_ubuntu="ubuntu adm"
  check "access_problems: ubuntu not in sudo -> refused" grep -q "ubuntu is not in group sudo" <<<"$(access_problems)"
  STUB_GROUPS_ubuntu="ubuntu adm sudo" STUB_GROUPS_alice="alice docker"
  check "access_problems: active admin outside sudo -> refused" grep -q "named admin" <<<"$(access_problems)"
  : >"$HOME_ROOT/alice/.ssh/authorized_keys"
  check "access_problems: revoked admin (empty keys) ignored" [ -z "$(access_problems)" ]
  unset -f id
  rm -rf "$tmp"

  local rc
  bash "$HARDEN" >/dev/null 2>&1
  rc=$?
  check "no arguments -> usage, exit 64" [ "$rc" = 64 ]
  bash "$HARDEN" --verify --dry-run >/dev/null 2>&1
  rc=$?
  check "--dry-run only with --apply (exit 64)" [ "$rc" = 64 ]
  bash "$HARDEN" --apply --verify >/dev/null 2>&1
  rc=$?
  check "two modes rejected (exit 64)" [ "$rc" = 64 ]
  bash "$HARDEN" --disarm --expect-armed >/dev/null 2>&1
  rc=$?
  check "--expect-armed only with --verify (exit 64)" [ "$rc" = 64 ]
}

# ---------------------------------------------------------------------------
# Container layer: everything below runs INSIDE the ubuntu:22.04 container.
# ---------------------------------------------------------------------------
in_container() {
  set +e
  export DEBIAN_FRONTEND=noninteractive
  if ! { apt-get update -qq >/dev/null && apt-get install -y -qq openssh-server iptables ufw sudo iproute2 >/dev/null 2>&1; }; then
    echo "FATAL: apt install failed in container"
    exit 1
  fi
  mkdir -p /run/sshd
  useradd -m -s /bin/bash -G sudo ubuntu
  # Lightsail ships this; the 99- file mimics user_data (VC-651).
  printf 'PasswordAuthentication no\n' >/etc/ssh/sshd_config.d/60-cloudimg-settings.conf
  printf 'PermitRootLogin no\nPasswordAuthentication no\nChallengeResponseAuthentication no\n' >/etc/ssh/sshd_config.d/99-vc651-hardening.conf

  # systemd stubs: state in /tmp/sysd; systemd-run records the armed command.
  mkdir -p /tmp/sysd /usr/local/stub
  cat >/usr/local/stub/systemctl <<'EOS'
#!/bin/bash
S=/tmp/sysd; echo "systemctl $*" >>$S/calls
q=0; args=()
for a in "$@"; do case "$a" in --quiet|-q) q=1 ;; --now) now=1 ;; *) args+=("$a") ;; esac; done
cmd=${args[0]}; set -- "${args[@]:1}"
case "$cmd" in
  is-active) for u; do [ -e "$S/$u.active" ] || { [ $q = 1 ] || echo inactive; exit 3; }; done; [ $q = 1 ] || echo active ;;
  is-enabled) for u; do [ -e "$S/$u.enabled" ] || { [ $q = 1 ] || echo disabled; exit 1; }; done; [ $q = 1 ] || echo enabled ;;
  enable) for u; do touch "$S/$u.enabled"; [ "${now:-0}" = 1 ] && touch "$S/$u.active"; done; true ;;
  disable) for u; do rm -f "$S/$u.enabled"; done ;;
  stop) for u; do rm -f "$S/$u.active"; done ;;
  *) true ;;
esac
EOS
  cat >/usr/local/stub/systemd-run <<'EOS'
#!/bin/bash
S=/tmp/sysd; unit=""; for a; do case "$a" in --unit=*) unit=${a#--unit=} ;; esac; done
shift $(( $# - 2 )); echo "$1 $2" > $S/armed-cmd; touch "$S/$unit.timer.active"; echo "Running timer as unit: $unit.timer"
EOS
  printf '#!/bin/bash\ntrue\n' >/usr/local/stub/logger
  chmod +x /usr/local/stub/*
  export PATH="/usr/local/stub:$PATH"
  touch /tmp/sysd/ssh.active /tmp/sysd/apt-daily.timer.active /tmp/sysd/apt-daily.timer.enabled

  # Stand-ins for the tables Docker and ufw own (iptables-nft): they must survive.
  iptables -t nat -N DOCKER && iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
  iptables -t filter -N sah-test-docker-user

  # What the deploy's configure-host-firewall.sh does (VC-647): ufw active, 22/80/443.
  ufw default deny incoming >/dev/null && ufw default allow outgoing >/dev/null &&
    for p in 22/tcp 80/tcp 443/tcp; do ufw allow "$p" comment 'VC-647' >/dev/null; done &&
    ufw --force enable >/dev/null 2>&1
  UFW_ACTIVE=0
  ufw status | grep -q '^Status: active' && UFW_ACTIVE=1
  echo "# ufw active in container: $UFW_ACTIVE"

  H="bash /work/docker/host/harden-host.sh"

  echo "# container: ubuntu:22.04, $(nft --version 2>/dev/null || echo 'nft absent'), $(ssh -V 2>&1)"

  # Refusal path: ubuntu outside sudo -> nothing changes, nothing armed.
  gpasswd -d ubuntu sudo >/dev/null
  $H --apply >/tmp/out 2>&1
  rc=$?
  check "apply refuses when ubuntu is not in sudo (exit 1)" [ "$rc" = 1 ]
  check "  ...and changed nothing (no drop-in, not armed)" bash -c '[ ! -e /etc/ssh/sshd_config.d/01-sah-hardening.conf ] && [ ! -e /tmp/sysd/sah-harden-rollback.timer.active ]'
  usermod -aG sudo ubuntu

  $H --apply --dry-run >/tmp/dry 2>&1
  rc=$?
  check "apply --dry-run exits 0 on a fresh host" [ "$rc" = 0 ]
  check "  ...reports packages it would install" grep -q "WOULD INSTALL package nftables" /tmp/dry
  check "  ...and changed nothing" bash -c '[ ! -e /etc/ssh/sshd_config.d/01-sah-hardening.conf ] && ! command -v nft >/dev/null'

  $H --verify >/tmp/v0 2>&1
  rc=$?
  check "verify on an unhardened host -> drift (exit 2)" [ "$rc" = 2 ]

  $H --apply >/tmp/apply 2>&1
  rc=$?
  check "apply succeeds (exit 0)" [ "$rc" = 0 ] || sed 's/^/      /' /tmp/apply
  check "  ...armed the dead-man before the first change" bash -c 'a=$(grep -n "dead-man armed" /tmp/apply | cut -d: -f1); b=$(grep -n "TrustedUserCAKeys (before)" /tmp/apply | cut -d: -f1); [ -n "$a" ] && [ "$a" -lt "$b" ]'
  check "  ...loaded table inet sah_host_fw with policy drop" bash -c 'nft list table inet sah_host_fw | grep -q "policy drop"'
  check "  ...Docker nat table survived" bash -c 'iptables -t nat -S DOCKER >/dev/null 2>&1 && iptables -t nat -S PREROUTING | grep -q DOCKER'
  check "  ...pre-existing filter chain survived" bash -c 'iptables -t filter -S sah-test-docker-user >/dev/null 2>&1'
  check "  ...sshd -T effective settings hardened" bash -c 'sshd -T | grep -qx "allowgroups sudo" && sshd -T | grep -qx "permitrootlogin no" && sshd -T | grep -qx "kbdinteractiveauthentication no"'
  check "  ...boot unit written but not yet enabled" bash -c '[ -f /etc/systemd/system/sah-host-fw.service ] && [ ! -e /tmp/sysd/sah-host-fw.service.enabled ]'
  check "  ...apt-config: security-only origins, no reboot" bash -c 'apt-config dump | grep "^Unattended-Upgrade::Allowed-Origins:: " | grep -qv -- -security && exit 1; apt-config dump | grep -qx "Unattended-Upgrade::Automatic-Reboot \"false\";"'
  check "  ...never started/enabled/reloaded nftables.service" bash -c '! grep -E "systemctl (enable|disable|start|stop|restart|reload|mask).*nftables" /tmp/sysd/calls'

  if [ "$UFW_ACTIVE" = 1 ]; then
    check "  ...ufw still active with its own chains" bash -c 'ufw status | grep -q "^Status: active" && iptables -S ufw-user-input | grep -q "dport 443"'
    ufw reload >/dev/null 2>&1
    check "  ...a later ufw reload (next deploy) keeps our table" bash -c 'nft list table inet sah_host_fw >/dev/null 2>&1'
  fi
  $H --verify --expect-armed >/tmp/varmed 2>&1
  rc=$?
  check "verify --expect-armed after apply -> OK (exit 0)" [ "$rc" = 0 ] || grep -E "drift|error" /tmp/varmed | sed 's/^/      /'
  $H --verify >/tmp/vplain 2>&1
  rc=$?
  check "plain verify while armed -> exit 3" [ "$rc" = 3 ]

  # Fire the dead-man: run exactly what systemd-run was given.
  cp -a /etc/ssh/sshd_config.d /tmp/sshd.d.bak
  bash -c "$(cat /tmp/sysd/armed-cmd)"
  check "dead-man: table deleted" bash -c '! nft list table inet sah_host_fw >/dev/null 2>&1'
  check "dead-man: our drop-in removed, user_data 99- kept" bash -c '[ ! -e /etc/ssh/sshd_config.d/01-sah-hardening.conf ] && [ -e /etc/ssh/sshd_config.d/99-vc651-hardening.conf ]'
  check "dead-man: Docker nat table still intact" bash -c 'iptables -t nat -S DOCKER >/dev/null 2>&1'
  rm -f /tmp/sysd/sah-harden-rollback.timer.active # a fired transient timer is gone
  $H --disarm >/tmp/dis 2>&1
  rc=$?
  check "disarm after the rollback fired -> refused (exit 1)" [ "$rc" = 1 ]
  $H --verify --expect-armed >/dev/null 2>&1
  rc=$?
  check "verify --expect-armed after the rollback fired -> drift (exit 2)" [ "$rc" = 2 ]

  # Second apply (idempotent path) then the happy disarm.
  $H --apply >/tmp/apply2 2>&1
  rc=$?
  check "re-apply succeeds" [ "$rc" = 0 ]
  check "  ...ruleset reload is idempotent (one table)" [ "$(nft list tables | grep -c 'inet sah_host_fw')" = 1 ]
  $H --disarm >/tmp/dis2 2>&1
  rc=$?
  check "disarm succeeds" [ "$rc" = 0 ] || sed 's/^/      /' /tmp/dis2
  check "  ...boot unit enabled, dead-man stopped" bash -c '[ -e /tmp/sysd/sah-host-fw.service.enabled ] && [ ! -e /tmp/sysd/sah-harden-rollback.timer.active ]'
  # Stamps a real host has after unattended-upgrades ran.
  mkdir -p /var/lib/apt/periodic && touch /var/lib/apt/periodic/update-success-stamp /var/lib/apt/periodic/unattended-upgrades-stamp
  touch /tmp/sysd/apt-daily-upgrade.timer.active
  $H --verify >/tmp/vfinal 2>&1
  rc=$?
  check "final verify -> OK (exit 0)" [ "$rc" = 0 ] || grep -E "drift|error" /tmp/vfinal | sed 's/^/      /'
  check "  ...verify output has no IPv4 address" bash -c '! grep -E "([0-9]{1,3}\.){3}[0-9]{1,3}" /tmp/vfinal | grep -vE "127\.0\.0\.1|0\.0\.0\.0|[0-9]+\.[0-9]+\.[0-9]+-|ubuntu[0-9.]+|[0-9]\.[0-9]+\.[0-9]+\.[0-9]+[a-z~+-]" | grep -q .'

  # Drift detection.
  echo "PermitRootLogin yes" >/etc/ssh/sshd_config.d/00-evil.conf
  $H --verify >/tmp/vdrift 2>&1
  rc=$?
  check "an earlier sshd drop-in re-enabling root -> drift (exit 2)" bash -c '[ "$1" = 2 ] && grep -q "permitrootlogin=yes" /tmp/vdrift' _ "$rc"
  rm -f /etc/ssh/sshd_config.d/00-evil.conf
  touch -d '10 days ago' /var/lib/apt/periodic/unattended-upgrades-stamp
  $H --verify >/dev/null 2>&1
  rc=$?
  check "unattended-upgrades stamp 10 days old -> exit 3" [ "$rc" = 3 ]
  touch /var/lib/apt/periodic/unattended-upgrades-stamp

  $H --rollback >/dev/null 2>&1
  check "--rollback removes table and drop-in" bash -c '! nft list table inet sah_host_fw >/dev/null 2>&1 && [ ! -e /etc/ssh/sshd_config.d/01-sah-hardening.conf ] && [ ! -e /tmp/sysd/sah-host-fw.service.enabled ]'

  echo "--- sample: final verify evidence (container) ---"
  sed -n '1,200p' /tmp/vfinal
}

run_container() {
  command -v docker >/dev/null 2>&1 || {
    echo "FATAL: --container needs docker" >&2
    exit 1
  }
  local root
  root="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # Privileged for nft/iptables inside the container's OWN network namespace (default
  # bridge network: no host networking, no published ports).
  docker run --rm --privileged -v "$root:/work:ro" ubuntu:22.04 \
    bash /work/docker/__tests__/harden-host.test.sh --in-container
}

case "${1:-}" in
  --container) run_container ;;
  --in-container)
    in_container
    echo "# $PASS passed, $FAIL failed"
    [ "$FAIL" = 0 ]
    ;;
  *)
    run_unit
    echo "# $PASS passed, $FAIL failed"
    [ "$FAIL" = 0 ]
    ;;
esac
