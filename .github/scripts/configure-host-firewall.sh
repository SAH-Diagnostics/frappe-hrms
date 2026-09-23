#!/bin/bash
set -e

# configure-host-firewall.sh
# Purpose: Put the host firewall (ufw) on the ERP instance into a default-deny inbound
#          state that allows only SSH, HTTP and HTTPS (VC-647). Idempotent: a host that
#          is already in this state is left untouched, so repeated deploys are no-ops.
# Arguments:
#   $1 - lightsail_user
#   $2 - lightsail_host
#   $3 - lightsail_port
#   $4 - ssh_key_path (default: ~/.ssh/lightsail_key)
#
# Allowed ports:
#   80, 443 - nginx, the only public entry point to Frappe
#   22      - SSH. Source restriction is enforced at the Lightsail firewall
#             (infrastructure repo, ssh_allowed_cidrs), not here: the deploy runner has
#             to reach the host to run this script at all, and its address changes per run.
#
# Frappe (8000) and Socket.IO (9000) are deliberately not allowed. They are bound to
# 127.0.0.1 in docker/docker-compose.yml, which is the control that matters for them:
# ufw cannot block a port that Docker publishes on 0.0.0.0, because Docker's own
# iptables rules act in the FORWARD chain before ufw's INPUT rules are consulted.
#
# Enabling ufw (or changing its default policy) reloads iptables, which drops the chains
# Docker maintains. Docker is restarted afterwards so that the containers keep working.
# That only happens on the run that changes something; later runs change nothing.

if [ $# -lt 3 ]; then
    echo "Usage: $0 <lightsail_user> <lightsail_host> <lightsail_port> [ssh_key_path]"
    echo "Purpose: Configure a default-deny host firewall (ufw) on the remote instance"
    exit 1
fi

LIGHTSAIL_USER="$1"
LIGHTSAIL_HOST="$2"
LIGHTSAIL_PORT="$3"
SSH_KEY_PATH="${4:-~/.ssh/lightsail_key}"

# Expand ~ to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Configuring host firewall on $LIGHTSAIL_USER@$LIGHTSAIL_HOST:$LIGHTSAIL_PORT"

# The heredoc delimiter is quoted: everything below runs verbatim on the instance.
ssh -i "$SSH_KEY_PATH" -p "$LIGHTSAIL_PORT" -o StrictHostKeyChecking=accept-new "$LIGHTSAIL_USER@$LIGHTSAIL_HOST" 'bash -s' <<'REMOTE_EOF'
set -e

if ! command -v ufw >/dev/null 2>&1; then
    echo "=== Installing ufw ==="
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
fi

changed=0

default_policy() {
    sudo grep -E "^DEFAULT_${1}_POLICY=" /etc/default/ufw | cut -d= -f2 | tr -d '"'
}

echo "=== Default policies ==="
if [ "$(default_policy INPUT)" != "DROP" ]; then
    sudo ufw default deny incoming
    changed=1
else
    echo "Inbound default already deny"
fi
if [ "$(default_policy OUTPUT)" != "ACCEPT" ]; then
    sudo ufw default allow outgoing
    changed=1
else
    echo "Outbound default already allow"
fi

echo "=== Allow rules ==="
status=$(sudo ufw status)
for rule in 22/tcp 80/tcp 443/tcp; do
    if grep -qE "^${rule}[[:space:]]+ALLOW[[:space:]]+Anywhere([[:space:]]|$)" <<<"$status"; then
        echo "$rule already allowed"
    else
        sudo ufw allow "$rule" comment 'VC-647'
        changed=1
    fi
done

echo "=== Enabling ==="
if grep -q '^Status: active' <<<"$status"; then
    echo "ufw already active"
else
    sudo ufw --force enable
    changed=1
fi

if [ "$changed" = "1" ] && systemctl is-active --quiet docker; then
    echo "=== Restarting Docker (ufw reloaded iptables and dropped Docker's chains) ==="
    sudo systemctl restart docker
fi

echo "=== Resulting host firewall ==="
sudo ufw status verbose
REMOTE_EOF

echo "✓ Host firewall configured"
exit 0
