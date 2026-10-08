#!/usr/bin/env bash
#
# Host hardening for the ERP (Frappe/HRMS) Lightsail host, Ubuntu 22.04.
#
# Ported from the Virtual Clinics backend hardening (medplum deploy/host/harden-host.sh,
# Amazon Linux 2023) and kept compatible with what the instance's first-boot user_data
# already does (infrastructure repo, terraform/frappe/<env>/instance/init_instance.sh):
#   - user_data creates named admins (groups sudo,docker; markers in /etc/sah-admin-accounts.d)
#     and writes /etc/ssh/sshd_config.d/99-vc651-hardening.conf. This script never creates,
#     changes or revokes accounts; it only makes sure sshd keeps admitting them.
#   - user_data and every deploy (.github/scripts/configure-host-firewall.sh) enable ufw.
#     This script never touches ufw. See "Host firewall" below.
#
# Invoked by .github/workflows/harden-lightsail-host.yml (dispatch only), never by a deploy:
#
#   sudo bash harden-host.sh --verify [--expect-armed]   read-only evidence; non-zero on drift
#   sudo bash harden-host.sh --apply [--dry-run]         arm the dead-man, then apply (idempotent)
#   sudo bash harden-host.sh --disarm                    persist the firewall unit, stop the dead-man
#   sudo bash harden-host.sh --rollback                  undo sshd drop-in + firewall table now
#
# Lock-out safety: --apply arms a transient systemd timer (sah-harden-rollback, 5 minutes)
# BEFORE it changes anything. The caller must then open a FRESH ssh connection, run
# --verify --expect-armed, and only then run --disarm in yet another invocation. If that
# never happens (lock-out, runner lost, job cancelled) the timer deletes the nft table,
# disables the boot unit, removes the sshd drop-in and reloads sshd.
#
# SSH: /etc/ssh/sshd_config.d/01-sah-hardening.conf. Ubuntu's sshd_config includes
# sshd_config.d/*.conf on its first line and sshd keeps the FIRST value it reads per
# keyword, so 01- wins over 60-cloudimg-settings.conf and the user_data 99- file (which is
# left in place: it says the same thing and survives a rollback of this one).
# AllowGroups sudo: `ubuntu` (CI deploy + Lightsail browser SSH) and every user_data named
# admin are in `sudo`. --apply refuses to run if that is not true on the host.
#
# Host firewall: nftables table `inet sah_host_fw`, input hook, policy drop. It lives
# beside ufw (iptables-nft tables `ip filter`/`ip6 filter`): a packet has to be accepted by
# every input base chain, so the two layers stack, and both allow 22/80/443. Neither the
# distro nftables.service nor /etc/nftables.conf is used: that file starts with
# `flush ruleset`, which would also wipe ufw's and Docker's tables. Our own oneshot unit
# (sah-host-fw.service) only ever creates or deletes our table. Only an input chain:
# Docker-published ports are DNATed and cross FORWARD, so they are kept private by
# binding to 127.0.0.1 (docker/docker-compose.yml), which --verify checks. Outbound
# (RDS, S3, Let's Encrypt, apt) is not filtered; replies come back as established.
#
# Patching: unattended-upgrades, security origins only, no automatic reboot. Docker
# Engine/containerd come from download.docker.com, which is not a security origin, so
# they are never upgraded unattended (parity with the medplum dnf-automatic exclude).
#
# Every target path is env-overridable so docker/__tests__/harden-host.test.sh can run
# the logic in a throwaway container. Nothing in the output prints an IP address: the
# repository and its Actions logs are public.
set -euo pipefail

SSHD_DROPIN="${SSHD_DROPIN:-/etc/ssh/sshd_config.d/01-sah-hardening.conf}"
NFT_RULESET="${NFT_RULESET:-/etc/nftables/sah-host-fw.nft}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
APT_CONF="${APT_CONF:-/etc/apt/apt.conf.d/52sah-unattended-upgrades}"
ROLLBACK_SCRIPT="${ROLLBACK_SCRIPT:-/usr/local/sbin/sah-harden-rollback.sh}"
STATE_DIR="${STATE_DIR:-/var/lib/sah-harden}"
MARKER_DIR="${MARKER_DIR:-/etc/sah-admin-accounts.d}"
HOME_ROOT="${HOME_ROOT:-/home}"
REBOOT_REQUIRED_FILE="${REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
APT_PERIODIC_DIR="${APT_PERIODIC_DIR:-/var/lib/apt/periodic}"
ROLLBACK_SECS="${ROLLBACK_SECS:-300}"
NFT_BIN="${NFT_BIN:-/usr/sbin/nft}"

CI_USER="ubuntu"
SSH_GROUP="sudo"
SSH_SERVICE="ssh"
FW_TABLE="sah_host_fw"
FW_UNIT="sah-host-fw.service"
ROLLBACK_UNIT="sah-harden-rollback"
ROLLED_BACK_MARKER="$STATE_DIR/rolled-back"
# unattended-upgrades stamps older than this fail verify: the job is not running.
MAX_STAMP_AGE_DAYS=3

MODE=""
DRY_RUN=0
EXPECT_ARMED=0
NO_DEAD_MAN=0
DRIFT=0
STALE=0

log() { echo "[harden-host] $*"; }
warn() { echo "::warning::$*"; }
die() {
  echo "::error::$*" >&2
  exit 1
}
drift() {
  warn "drift: $*"
  DRIFT=1
}
section() {
  echo
  echo "=== $* ==="
}

# ---------------------------------------------------------------------------
# Renderers: print managed file content, no side effects.
# ---------------------------------------------------------------------------

render_sshd_dropin() {
  cat <<EOF
# Managed by docker/host/harden-host.sh (frappe-hrms) - local edits are overwritten.
# Key-only SSH, no root, no X11. AllowGroups $SSH_GROUP admits $CI_USER (CI deploy and
# Lightsail browser SSH) and the named admins from user_data (groups sudo,docker).
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowGroups $SSH_GROUP
EOF
}

render_nft_ruleset() {
  # First two statements make the file idempotent in one atomic transaction. ICMPv6
  # (ND/RA/PMTU) and DHCP client replies are accepted before the invalid-drop, because
  # conntrack can classify some of them as invalid. Never a ruleset-wide flush.
  cat <<EOF
# Managed by docker/host/harden-host.sh (frappe-hrms) - local edits are overwritten.
# Loaded by $FW_UNIT. Touches only table inet $FW_TABLE; ufw and Docker tables survive.
table inet $FW_TABLE
delete table inet $FW_TABLE
table inet $FW_TABLE {
  chain input {
    type filter hook input priority filter; policy drop;

    iif "lo" accept
    ct state established,related accept

    meta l4proto ipv6-icmp accept
    meta l4proto icmp accept
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept

    ct state invalid drop

    iifname "docker0" accept
    iifname "br-*" accept

    tcp dport { 22, 80, 443 } accept
  }
}
EOF
}

render_fw_unit() {
  # Same boot ordering as ufw.service: early, before any network is configured.
  cat <<EOF
# Managed by docker/host/harden-host.sh (frappe-hrms), installed by --disarm.
# Loads the host firewall table inet $FW_TABLE at boot. Deliberately not nftables.service:
# /etc/nftables.conf starts with 'flush ruleset', which would also wipe ufw and Docker.
[Unit]
Description=SAH host firewall (nft table inet $FW_TABLE)
Documentation=file://$NFT_RULESET
DefaultDependencies=no
After=local-fs.target
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT_BIN -f $NFT_RULESET
ExecStop=-$NFT_BIN delete table inet $FW_TABLE

[Install]
WantedBy=multi-user.target
EOF
}

render_apt_conf() {
  # Sorts after 20auto-upgrades and 50unattended-upgrades, so its scalars win and the
  # #clear directives replace (not extend) the distro origin list.
  cat <<'EOF'
// Managed by docker/host/harden-host.sh (frappe-hrms) - local edits are overwritten.
// Security updates only, applied daily; never reboots (kernel reboots are manual).
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESMApps:${distro_codename}-apps-security";
  "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
}

render_rollback_script() {
  cat <<EOF
#!/bin/bash
# Managed by docker/host/harden-host.sh. Fired by the $ROLLBACK_UNIT timer when the
# workflow never confirmed fresh SSH access after --apply, or run by hand (--rollback).
# Every step tolerates "already gone". ufw and the user_data sshd file are not touched.
$NFT_BIN delete table inet $FW_TABLE 2>/dev/null || true
systemctl disable $FW_UNIT 2>/dev/null || true
rm -f $SSHD_DROPIN
if sshd -t; then
  systemctl reload $SSH_SERVICE || true
fi
mkdir -p $STATE_DIR
date -u +%FT%TZ > $ROLLED_BACK_MARKER
logger -t $ROLLBACK_UNIT "host hardening rolled back (nft table and sshd drop-in removed)" || true
EOF
}

# ---------------------------------------------------------------------------
# Pure helpers.
# ---------------------------------------------------------------------------

sshd_effective_missing() {
  # Reads `sshd -T` on stdin; prints each expected setting that is not in effect.
  awk -v grp="$SSH_GROUP" '
    { k = tolower($1) }
    k == "permitrootlogin" { prl = $2 }
    k == "passwordauthentication" { pa = $2 }
    k == "kbdinteractiveauthentication" { kia = $2 }
    k == "x11forwarding" { x11 = $2 }
    k == "allowgroups" { for (i = 2; i <= NF; i++) if (!($i in ag)) { ag[$i] = 1; n++ } }
    k == "allowusers" { au = au " " $2 }
    END {
      if (prl != "no") print "permitrootlogin=" prl
      if (pa != "no") print "passwordauthentication=" pa
      if (kia != "no") print "kbdinteractiveauthentication=" kia
      if (x11 != "no") print "x11forwarding=" x11
      if (!(grp in ag) || n != 1) print "allowgroups is not exactly " grp
      if (au != "") print "allowusers is set (would also have to match):" au
    }'
}

in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx -- "$2"; }

# Named admins provisioned by user_data that can still log in (non-empty key file).
active_admins() {
  local m u
  for m in "$MARKER_DIR"/*; do
    [ -e "$m" ] || continue
    u=$(basename "$m")
    if id "$u" >/dev/null 2>&1 && [ -s "$HOME_ROOT/$u/.ssh/authorized_keys" ]; then
      echo "$u"
    fi
  done
}

# Prints the problems that would lock someone out under AllowGroups sudo; empty = safe.
access_problems() {
  local u
  if ! id "$CI_USER" >/dev/null 2>&1; then
    echo "user $CI_USER does not exist"
  elif ! in_group "$CI_USER" "$SSH_GROUP"; then
    echo "$CI_USER is not in group $SSH_GROUP (CI deploys would be locked out)"
  fi
  for u in $(active_admins); do
    in_group "$u" "$SSH_GROUP" || echo "a named admin (marker in $MARKER_DIR) with keys is not in group $SSH_GROUP"
  done
}

file_age_days() {
  local now mtime
  now=$(date +%s)
  mtime=$(stat -c %Y "$1" 2>/dev/null) || return 1
  echo $(((now - mtime) / 86400))
}

# Reads `apt-get -s dist-upgrade` on stdin; prints packages coming from a -security pocket.
pending_security_pkgs() {
  awk '/^Inst / && /-security/ { print $2 }'
}

# The repository is public, so verify output (workflow logs and the evidence artifact) is
# public too. By default it reports patch state as counts only - no kernel version, no
# package names - so it does not publish what is unpatched. HARDEN_VERBOSE=1 adds the
# detail for someone running the script on the host itself.
detail() {
  [ "${HARDEN_VERBOSE:-0}" = "1" ] || return 0
  echo "$*"
}

# summarise_pending <newline-separated packages>: one line, count only unless verbose.
summarise_pending() {
  local n
  if [ -z "$1" ]; then
    echo "pending security updates: none"
    return 0
  fi
  n=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
  warn "$n security update(s) pending (held, phased or needing a dist-upgrade)"
  detail "  packages: $(printf '%s' "$1" | tr '\n' ' ')"
}

# Reads `docker ps --format "{{.Names}} {{.Ports}}"` on stdin; prints published mappings
# that are not bound to loopback.
non_loopback_ports() {
  local name ports m
  local -a maps
  while read -r name ports; do
    [ -n "${name:-}" ] || continue
    IFS=', ' read -ra maps <<<"${ports:-}"
    for m in "${maps[@]}"; do
      case "$m" in *'->'*) ;; *) continue ;; esac
      case "$m" in
        127.0.0.1:* | '[::1]:'*) ;;
        *) echo "$name $m" ;;
      esac
    done
  done
}

install_content() {
  # install_content <mode> <dest>  (content on stdin). Atomic: temp file + rename.
  local mode=$1 dest=$2 tmp
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp "$(dirname "$dest")/.sah-harden.XXXXXX")
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
}

verify_file_matches() {
  # verify_file_matches <label> <path> <renderer>
  local label=$1 path=$2 renderer=$3
  if [ ! -f "$path" ]; then
    drift "$label missing ($path)"
  elif [ "$($renderer)" != "$(cat "$path")" ]; then
    drift "$label differs from the managed content ($path)"
  else
    echo "$label: OK ($path)"
  fi
}

# Dry-run report: would this managed file change?
plan_file() {
  local label=$1 path=$2 renderer=$3
  if [ ! -f "$path" ]; then
    echo "WOULD CREATE $label ($path):"
    $renderer | sed 's/^/    + /'
  elif [ "$($renderer)" != "$(cat "$path")" ]; then
    echo "WOULD REWRITE $label ($path):"
    diff <(cat "$path") <($renderer) | sed 's/^/    /' || true
  else
    echo "unchanged: $label ($path)"
  fi
}

have_nft() { [ -x "$NFT_BIN" ] || command -v nft >/dev/null 2>&1; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# ---------------------------------------------------------------------------
# Appliers.
# ---------------------------------------------------------------------------

print_trusted_ca() {
  # Lightsail browser SSH relies on TrustedUserCAKeys; prove the drop-in left it alone.
  log "sshd TrustedUserCAKeys ($1): $(sshd -T 2>/dev/null | grep -i '^trustedusercakeys' || echo '<none>')"
}

ensure_packages() {
  # Before the dead-man is armed, so a slow apt run never eats into the 5-minute window.
  local missing=() p
  for p in nftables unattended-upgrades; do pkg_installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  log "installing ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ||
    die "could not install ${missing[*]}; nothing changed"
}

arm_rollback() {
  render_rollback_script | install_content 755 "$ROLLBACK_SCRIPT"
  # A previous run's transient units (fired or failed) would make systemd-run refuse the
  # fixed unit name, so clear them first.
  systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "$ROLLBACK_UNIT.service" "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
  rm -f "$ROLLED_BACK_MARKER"
  systemd-run --unit="$ROLLBACK_UNIT" --on-active="$ROLLBACK_SECS" /bin/bash "$ROLLBACK_SCRIPT"
  systemctl is-active --quiet "$ROLLBACK_UNIT.timer" || die "dead-man did not arm; nothing changed"
  log "dead-man armed: $ROLLBACK_UNIT fires in ${ROLLBACK_SECS}s unless --disarm runs"
}

apply_sshd() {
  local backup="" missing
  print_trusted_ca before
  if [ -f "$SSHD_DROPIN" ]; then
    backup=$(mktemp)
    cp -p "$SSHD_DROPIN" "$backup"
  fi
  render_sshd_dropin | install_content 600 "$SSHD_DROPIN"
  mkdir -p /run/sshd
  if ! sshd -t; then
    if [ -n "$backup" ]; then mv -f "$backup" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
    die "sshd -t rejected the drop-in; previous state restored"
  fi
  [ -z "$backup" ] || rm -f "$backup"
  # reload, not restart: existing sessions (including this one) stay up.
  systemctl reload "$SSH_SERVICE"
  print_trusted_ca after
  missing=$(sshd -T 2>/dev/null | sshd_effective_missing)
  [ -z "$missing" ] || die "sshd effective config not as expected: $(echo "$missing" | tr '\n' ';')"
  log "sshd drop-in applied and reloaded"
}

apply_nft() {
  local tmp
  tmp=$(mktemp)
  render_nft_ruleset >"$tmp"
  "$NFT_BIN" -c -f "$tmp" || {
    rm -f "$tmp"
    die "nft -c rejected the rendered ruleset"
  }
  install_content 600 "$NFT_RULESET" <"$tmp"
  rm -f "$tmp"
  "$NFT_BIN" -f "$NFT_RULESET"
  # The boot unit file is written now but only enabled by --disarm, after a fresh SSH
  # connection proved access: a reboot inside the window must not keep a bad ruleset.
  render_fw_unit | install_content 644 "$UNIT_DIR/$FW_UNIT"
  systemctl daemon-reload
  log "nft table inet $FW_TABLE loaded (runtime only until --disarm)"
}

apply_patching() {
  render_apt_conf | install_content 644 "$APT_CONF"
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  log "unattended-upgrades: security origins only, daily, Automatic-Reboot=false"
}

# ---------------------------------------------------------------------------
# Commands.
# ---------------------------------------------------------------------------

cmd_apply_dry_run() {
  local problems tmp
  section "Plan (dry run: nothing is changed)"
  problems=$(access_problems)
  if [ -n "$problems" ]; then
    printf 'REFUSE: %s\n' "$problems"
  else
    echo "access precheck: OK ($CI_USER and named admins are in $SSH_GROUP)"
  fi
  for p in nftables unattended-upgrades; do
    pkg_installed "$p" && echo "package $p: installed" || echo "WOULD INSTALL package $p"
  done
  echo "WOULD ARM dead-man $ROLLBACK_UNIT (${ROLLBACK_SECS}s) before any change"
  plan_file "sshd drop-in" "$SSHD_DROPIN" render_sshd_dropin
  plan_file "nft ruleset" "$NFT_RULESET" render_nft_ruleset
  plan_file "firewall unit" "$UNIT_DIR/$FW_UNIT" render_fw_unit
  plan_file "apt unattended-upgrades conf" "$APT_CONF" render_apt_conf
  if have_nft; then
    tmp=$(mktemp)
    render_nft_ruleset >"$tmp"
    if "$NFT_BIN" -c -f "$tmp"; then echo "nft -c: rendered ruleset OK"; else echo "nft -c: REJECTED"; fi
    rm -f "$tmp"
  else
    echo "nft not installed: ruleset syntax not checked"
  fi
  [ -z "$problems" ] || return 1
}

cmd_apply() {
  local problems
  if [ "$DRY_RUN" = "1" ]; then
    cmd_apply_dry_run
    return
  fi
  problems=$(access_problems)
  [ -z "$problems" ] || die "refusing, AllowGroups $SSH_GROUP would lock out: $(echo "$problems" | tr '\n' ';') nothing changed"
  ensure_packages
  if [ "$NO_DEAD_MAN" = "1" ]; then
    warn "--no-dead-man: applying WITHOUT the rollback timer"
  else
    arm_rollback
  fi
  apply_sshd
  apply_nft
  apply_patching
  log "applied (runtime). Open a FRESH ssh connection, run --verify --expect-armed, then --disarm."
}

cmd_disarm() {
  [ ! -e "$ROLLED_BACK_MARKER" ] || die "the rollback already fired at $(cat "$ROLLED_BACK_MARKER"); hardening is NOT in place - re-run --apply"
  [ -f "$NFT_RULESET" ] || die "$NFT_RULESET missing; run --apply first"
  render_fw_unit | install_content 644 "$UNIT_DIR/$FW_UNIT"
  systemctl daemon-reload
  # ExecStart re-applies the idempotent ruleset, so --now only aligns the unit state.
  systemctl enable --now "$FW_UNIT"
  systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "$ROLLBACK_UNIT.service" "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
  systemctl is-active --quiet "$ROLLBACK_UNIT.timer" && die "$ROLLBACK_UNIT.timer is still active after disarm"
  # The timer may have fired between the check above and the stop.
  [ ! -e "$ROLLED_BACK_MARKER" ] || die "the rollback fired during disarm; hardening is NOT in place - re-run --apply"
  log "$FW_UNIT enabled; dead-man disarmed; hardening persisted"
}

cmd_rollback() {
  render_rollback_script | install_content 755 "$ROLLBACK_SCRIPT"
  systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
  /bin/bash "$ROLLBACK_SCRIPT"
  log "rollback executed"
}

cmd_verify() {
  local out missing problems n age fw_state pending u nadmins=0
  section "Host"
  grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>/dev/null || true
  detail "kernel: $(uname -r)"
  echo "uptime: $(uptime -p 2>/dev/null || uptime)"

  section "SSH"
  verify_file_matches "sshd drop-in" "$SSHD_DROPIN" render_sshd_dropin
  for u in "$(dirname "$SSHD_DROPIN")"/*.conf; do
    if [ -e "$u" ]; then echo "  sshd_config.d: $(basename "$u")"; fi
  done
  mkdir -p /run/sshd 2>/dev/null || true
  out=$(sshd -T 2>/dev/null || true)
  echo "$out" | grep -iE '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|x11forwarding|allowgroups|allowusers|pubkeyauthentication|trustedusercakeys) ' || true
  missing=$(echo "$out" | sshd_effective_missing)
  [ -z "$missing" ] || drift "sshd effective config: $(echo "$missing" | tr '\n' ';')"
  systemctl is-active --quiet "$SSH_SERVICE" || drift "$SSH_SERVICE.service is not active"

  section "Who sshd admits (AllowGroups $SSH_GROUP)"
  problems=$(access_problems)
  if [ -n "$problems" ]; then
    while read -r u; do drift "$u"; done <<<"$problems"
  else
    echo "$CI_USER in $SSH_GROUP: yes"
  fi
  # Counts only, no usernames: these logs are public.
  for u in $(active_admins); do nadmins=$((nadmins + 1)); done
  echo "named admins with keys (from user_data markers): $nadmins"

  section "Host firewall (nft table inet $FW_TABLE)"
  if ! have_nft; then
    drift "nft not installed (nftables package missing)"
  elif out=$("$NFT_BIN" list table inet "$FW_TABLE" 2>/dev/null); then
    echo "$out"
    echo "$out" | grep -q 'hook input .*policy drop' || drift "inet $FW_TABLE input chain is not policy drop"
  else
    drift "nft table inet $FW_TABLE not loaded"
  fi
  verify_file_matches "nft ruleset" "$NFT_RULESET" render_nft_ruleset
  if [ "$EXPECT_ARMED" = "1" ]; then
    echo "$FW_UNIT: not checked (--expect-armed: --disarm enables it)"
  else
    verify_file_matches "firewall unit" "$UNIT_DIR/$FW_UNIT" render_fw_unit
    systemctl is-enabled --quiet "$FW_UNIT" || drift "$FW_UNIT not enabled (firewall will not survive a reboot)"
    fw_state=$(systemctl is-active "$FW_UNIT" 2>/dev/null || true)
    echo "$FW_UNIT: ${fw_state:-unknown}"
    [ "$fw_state" = "active" ] || drift "$FW_UNIT is ${fw_state:-unknown}, not active"
  fi
  # /etc/nftables.conf starts with 'flush ruleset': enabled, it would wipe ufw and Docker.
  if systemctl is-enabled --quiet nftables.service 2>/dev/null; then
    drift "nftables.service is enabled (its 'flush ruleset' wipes ufw and Docker rules at boot)"
  else
    echo "nftables.service: not enabled (correct)"
  fi

  section "ufw (VC-647 deploy layer, managed by configure-host-firewall.sh, not by this script)"
  if command -v ufw >/dev/null 2>&1; then
    out=$(ufw status verbose 2>/dev/null || true)
    echo "$out"
    if grep -q '^Status: active' <<<"$out"; then
      for n in 22 80 443; do
        grep -qE "^${n}/tcp[[:space:]]+ALLOW IN[[:space:]]+Anywhere" <<<"$out" ||
          drift "ufw is active but does not allow ${n}/tcp (both layers must allow it)"
      done
    else
      warn "ufw is not active; the nft table is the only host firewall layer"
    fi
  else
    warn "ufw is not installed; the nft table is the only host firewall layer"
  fi

  section "Listening sockets and published container ports"
  ss -Hltnu 2>/dev/null | awk '{print "  " $1 " " $5}' | sort -u || true
  if command -v docker >/dev/null 2>&1; then
    out=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null || true)
    while read -r u; do [ -z "$u" ] || echo "  container: $u"; done <<<"$out"
    while read -r u; do
      [ -n "$u" ] && drift "container port published beyond loopback (bypasses both firewalls): $u"
    done < <(echo "$out" | non_loopback_ports)
  fi

  section "Patching (unattended-upgrades)"
  verify_file_matches "apt unattended-upgrades conf" "$APT_CONF" render_apt_conf
  pkg_installed unattended-upgrades || drift "unattended-upgrades not installed"
  out=$(apt-config dump 2>/dev/null || true)
  echo "$out" | grep -E '^(APT::Periodic::(Update-Package-Lists|Unattended-Upgrade)|Unattended-Upgrade::(Allowed-Origins|Origins-Pattern|Automatic-Reboot))' || true
  grep -qx 'APT::Periodic::Unattended-Upgrade "1";' <<<"$out" || drift "APT::Periodic::Unattended-Upgrade is not 1"
  grep -qx 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$out" || drift "Unattended-Upgrade::Automatic-Reboot is not false"
  if grep -E '^Unattended-Upgrade::(Allowed-Origins|Origins-Pattern):: ' <<<"$out" | grep -qv -- '-security'; then
    drift "an unattended-upgrades origin other than a -security pocket is enabled"
  fi
  for u in apt-daily.timer apt-daily-upgrade.timer; do
    systemctl is-enabled --quiet "$u" || drift "$u not enabled"
    systemctl is-active --quiet "$u" || drift "$u not active"
  done
  for u in update-success-stamp unattended-upgrades-stamp; do
    if age=$(file_age_days "$APT_PERIODIC_DIR/$u"); then
      echo "$u: ${age} day(s) old"
      if [ "$age" -gt "$MAX_STAMP_AGE_DAYS" ]; then
        echo "::error::$u is ${age} days old (> $MAX_STAMP_AGE_DAYS): unattended-upgrades is not running"
        STALE=1
      fi
    else
      warn "$APT_PERIODIC_DIR/$u missing (unattended-upgrades has never run)"
    fi
  done
  # Last run time only; the log itself names upgraded packages (see detail()).
  echo "last unattended-upgrades log entry: $(tail -n 1 /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | cut -c1-19)"
  if [ "${HARDEN_VERBOSE:-0}" = "1" ]; then
    tail -n 15 /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null || true
  fi
  # Read-only: the simulation uses the cached package lists, it does not refresh them.
  pending=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | pending_security_pkgs || true)
  summarise_pending "$pending"
  if [ -e "$REBOOT_REQUIRED_FILE" ]; then
    warn "reboot required (kernel/core libraries updated) - schedule it manually"
    detail "  packages: $(tr '\n' ' ' <"$REBOOT_REQUIRED_FILE.pkgs" 2>/dev/null)"
  else
    echo "reboot required: no"
  fi

  section "Certificate renewal"
  for u in snap.certbot.renew.timer certbot.timer; do
    echo "$u: enabled=$(systemctl is-enabled "$u" 2>/dev/null || true) active=$(systemctl is-active "$u" 2>/dev/null || true)"
  done

  section "Dead-man rollback"
  if systemctl is-active --quiet "$ROLLBACK_UNIT.timer"; then
    if [ "$EXPECT_ARMED" = "1" ]; then
      echo "$ROLLBACK_UNIT.timer: armed (expected before --disarm)"
    else
      echo "::error::$ROLLBACK_UNIT.timer is still armed"
      STALE=1
    fi
  else
    echo "$ROLLBACK_UNIT.timer: not armed"
    [ "$EXPECT_ARMED" = "0" ] || drift "--expect-armed but the dead-man is not armed (did it fire?)"
  fi
  [ ! -e "$ROLLED_BACK_MARKER" ] || drift "rollback fired at $(cat "$ROLLED_BACK_MARKER")"

  section "Result"
  if [ "$STALE" = "1" ]; then
    echo "verify: FAIL (patching not running, or rollback still armed) - exit 3"
    return 3
  elif [ "$DRIFT" = "1" ]; then
    echo "verify: DRIFT - exit 2"
    return 2
  fi
  echo "verify: OK"
}

usage() {
  cat >&2 <<'EOF'
usage: sudo bash harden-host.sh <mode> [options]

  --verify [--expect-armed]  read-only evidence report. Exit 0 OK, 2 drift, 3 patching not
                             running or dead-man still armed. --expect-armed is for the
                             check between --apply and --disarm (timer armed, boot unit
                             not yet enabled).
  --apply [--dry-run] [--no-dead-man]
                             arm the 5-minute dead-man, then apply sshd drop-in, nft table
                             (runtime) and unattended-upgrades. --dry-run prints the plan
                             and changes nothing.
  --disarm                   run from a FRESH ssh connection after --verify --expect-armed:
                             enables sah-host-fw.service, then stops the dead-man.
  --rollback                 remove the sshd drop-in and the nft table now.

Errors exit 1; a bad invocation prints this and exits 64.
Env: ROLLBACK_SECS (default 300) and the path variables at the top of the script.
EOF
  exit 64
}

set_mode() {
  [ -z "$MODE" ] || usage
  MODE=$1
}

main() {
  [ $# -gt 0 ] || usage
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify) set_mode verify ;;
      --apply) set_mode apply ;;
      --disarm) set_mode disarm ;;
      --rollback) set_mode rollback ;;
      --dry-run) DRY_RUN=1 ;;
      --expect-armed) EXPECT_ARMED=1 ;;
      --no-dead-man) NO_DEAD_MAN=1 ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$MODE" ] || usage
  [ "$DRY_RUN" = "0" ] || [ "$MODE" = "apply" ] || usage
  [ "$EXPECT_ARMED" = "0" ] || [ "$MODE" = "verify" ] || usage
  [ "$NO_DEAD_MAN" = "0" ] || [ "$MODE" = "apply" ] || usage
  [ "$(id -u)" -eq 0 ] || die "must run as root (sudo bash $0 --$MODE)"
  case "$MODE" in
    verify) cmd_verify ;;
    apply) cmd_apply ;;
    disarm) cmd_disarm ;;
    rollback) cmd_rollback ;;
  esac
}

# Sourced by the test harness with HARDEN_HOST_NO_MAIN=1 to exercise single functions.
if [ "${HARDEN_HOST_NO_MAIN:-0}" != "1" ]; then
  main "$@"
fi
