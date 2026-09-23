#!/bin/bash
set -euo pipefail

# lightsail-ssh-access.sh
# Purpose: Grant, then revoke, this GitHub Actions runner's access to SSH (22/tcp) on a
#          Lightsail instance for the duration of a workflow run (VC-647).
#
# SSH on the ERP instances is restricted at the Lightsail firewall to approved source
# addresses (infrastructure repo: terraform/frappe/<env>, variable ssh_allowed_cidrs).
# GitHub-hosted runners have no fixed address, so a run adds its own /32 to the SSH
# rule before connecting and removes it again when it finishes.
#
# The rule set is read, edited and written back in full with put-instance-public-ports
# rather than open-/close-instance-public-ports. That keeps the outcome independent of
# how Lightsail merges rules for the same port, and guarantees a rule is never written
# with an empty source list, which Lightsail treats as "allow from anywhere".
#
# Arguments:
#   $1 - ACTION: "open" or "close"
#   $2 - LIGHTSAIL_HOST: the instance's public IP (used to find the instance if $3 is empty)
#   $3 - LIGHTSAIL_INSTANCE_NAME (optional; otherwise looked up from the public IP)
#
# Environment:
#   GITHUB_ENV        - "open" records the granted CIDR as VC647_RUNNER_CIDR for "close"
#   VC647_RUNNER_CIDR - "close" removes this CIDR (falls back to detecting the IP again)
#
# IAM permissions required on the deploy credentials:
#   lightsail:GetInstances, lightsail:GetInstancePortStates, lightsail:PutInstancePublicPorts
#
# Exits non-zero when the firewall could not be read or changed. The workflow steps run
# with continue-on-error so a failure here is visible without aborting the job; the
# "Test SSH connection" step is what decides whether SSH is actually reachable.

if [ $# -lt 2 ]; then
    echo "Usage: $0 <open|close> <lightsail_host> [lightsail_instance_name]"
    echo "Purpose: Grant or revoke this runner's access to SSH on a Lightsail instance"
    exit 1
fi

ACTION="$1"
LIGHTSAIL_HOST="$2"
INSTANCE_NAME="${3:-}"

fail() {
    echo "::error::$*" >&2
    exit 1
}

case "$ACTION" in
    open|close) ;;
    *) fail "Unknown action '$ACTION' (expected open or close)" ;;
esac

detect_runner_cidr() {
    local ip="" url
    for url in https://checkip.amazonaws.com https://api.ipify.org; do
        ip=$(curl -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || ip=""
        [ -n "$ip" ] && break
    done
    if [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        return 1
    fi
    echo "${ip}/32"
}

resolve_instance_name() {
    if [ -n "$INSTANCE_NAME" ]; then
        echo "$INSTANCE_NAME"
        return
    fi
    aws lightsail get-instances \
        --query "instances[?publicIpAddress=='${LIGHTSAIL_HOST}'].name | [0]" \
        --output text 2>/dev/null || true
}

read_port_states() {
    local out
    if ! out=$(aws lightsail get-instance-port-states --instance-name "$1" --output json 2>&1); then
        fail "Could not read the Lightsail firewall (needs lightsail:GetInstancePortStates): $out"
    fi
    echo "$out"
}

# Usage: edit_port_infos add|remove <cidr> <file with get-instance-port-states output>
# Prints JSON: {"result": "changed"|"unchanged", "portInfos": [...]}
edit_port_infos() {
    python3 - "$1" "$2" "$3" <<'PYTHON_EOF'
import json
import sys

mode, cidr, state_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(state_file) as f:
    states = json.load(f).get("portStates", [])

infos = []
for s in states:
    infos.append({
        "fromPort": s["fromPort"],
        "toPort": s["toPort"],
        "protocol": s["protocol"],
        "cidrs": list(s.get("cidrs") or []),
        "ipv6Cidrs": list(s.get("ipv6Cidrs") or []),
        "cidrListAliases": list(s.get("cidrListAliases") or []),
    })

ssh_rules = [i for i in infos
             if i["protocol"].lower() == "tcp" and i["fromPort"] <= 22 <= i["toPort"]]

result = "unchanged"
if mode == "add":
    if any("0.0.0.0/0" in i["cidrs"] for i in ssh_rules):
        print("SSH is still open to 0.0.0.0/0 at the Lightsail firewall; "
              "no runner-specific rule is needed", file=sys.stderr)
    elif any(cidr in i["cidrs"] for i in ssh_rules):
        print(f"{cidr} is already allowed on 22/tcp", file=sys.stderr)
    elif ssh_rules:
        ssh_rules[0]["cidrs"].append(cidr)
        result = "changed"
    else:
        infos.append({"fromPort": 22, "toPort": 22, "protocol": "tcp",
                      "cidrs": [cidr], "ipv6Cidrs": [], "cidrListAliases": []})
        result = "changed"
elif mode == "remove":
    for i in ssh_rules:
        if cidr in i["cidrs"]:
            i["cidrs"] = [c for c in i["cidrs"] if c != cidr]
            result = "changed"
    # Never write back a rule with no sources: Lightsail would open it to everyone.
    infos = [i for i in infos if i["cidrs"] or i["ipv6Cidrs"] or i["cidrListAliases"]]

json.dump({"result": result, "portInfos": infos}, sys.stdout)
PYTHON_EOF
}

edit_result() {
    python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])' <<<"$1"
}

apply_port_infos() {
    local instance="$1" edited="$2" tmp out
    tmp=$(mktemp)
    python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["portInfos"], sys.stdout)' <<<"$edited" > "$tmp"
    if ! out=$(aws lightsail put-instance-public-ports --instance-name "$instance" --port-infos "file://$tmp" 2>&1); then
        rm -f "$tmp"
        fail "Could not update the Lightsail firewall (needs lightsail:PutInstancePublicPorts): $out"
    fi
    rm -f "$tmp"
}

# Printed at the end of every run so the deploy log records the public port list
# (the ticket's post-deployment check): expect 80, 443 and 22 from approved sources only.
show_public_ports() {
    echo "Public ports now in force at the Lightsail firewall:"
    aws lightsail get-instance-port-states --instance-name "$1" \
        --query 'portStates[].{fromPort:fromPort,toPort:toPort,protocol:protocol,cidrs:cidrs,ipv6Cidrs:ipv6Cidrs,cidrListAliases:cidrListAliases}' \
        --output json 2>/dev/null || echo "(could not read port states)"
}

INSTANCE=$(resolve_instance_name)
if [ -z "$INSTANCE" ] || [ "$INSTANCE" = "None" ]; then
    fail "Could not determine the Lightsail instance for host $LIGHTSAIL_HOST. Set LIGHTSAIL_INSTANCE_NAME in the deploy secret (Terraform writes it) or grant lightsail:GetInstances."
fi

STATE_FILE=$(mktemp)
trap 'rm -f "$STATE_FILE"' EXIT

case "$ACTION" in
    open)
        CIDR=$(detect_runner_cidr) || fail "Could not determine this runner's public IPv4 address"
        echo "Granting $CIDR access to 22/tcp on the Lightsail instance..."
        read_port_states "$INSTANCE" > "$STATE_FILE"
        EDITED=$(edit_port_infos add "$CIDR" "$STATE_FILE")
        if [ "$(edit_result "$EDITED")" = "changed" ]; then
            apply_port_infos "$INSTANCE" "$EDITED"
            echo "✓ Runner address added to the SSH rule"
        else
            echo "✓ No firewall change required"
        fi
        if [ -n "${GITHUB_ENV:-}" ]; then
            echo "VC647_RUNNER_CIDR=$CIDR" >> "$GITHUB_ENV"
        fi
        ;;
    close)
        CIDR="${VC647_RUNNER_CIDR:-}"
        if [ -z "$CIDR" ]; then
            CIDR=$(detect_runner_cidr) || fail "Could not determine this runner's public IPv4 address. Remove the runner's /32 from the SSH rule by hand, or re-apply Terraform, which restores the approved list."
        fi
        echo "Revoking $CIDR access to 22/tcp on the Lightsail instance..."
        read_port_states "$INSTANCE" > "$STATE_FILE"
        EDITED=$(edit_port_infos remove "$CIDR" "$STATE_FILE")
        if [ "$(edit_result "$EDITED")" = "changed" ]; then
            apply_port_infos "$INSTANCE" "$EDITED"
            echo "✓ Runner address removed from the SSH rule"
        else
            echo "✓ Nothing to revoke"
        fi
        ;;
esac

show_public_ports "$INSTANCE"
exit 0
