# Production ERP host hardening

`harden-host.sh` hardens the production ERP Lightsail host (`production-erp-instance`, Ubuntu 22.04). It is the counterpart of the Virtual Clinics backend hardening (medplum `deploy/host/harden-host.sh`). It runs only from the **Harden Lightsail host (prod ERP)** workflow (`.github/workflows/harden-lightsail-host.yml`), which is dispatched by hand. App deploys never run it.

## What it changes

| Control | File / object on the host | Notes |
|---|---|---|
| sshd: no root login, no passwords, no keyboard-interactive, no X11, `AllowGroups sudo` | `/etc/ssh/sshd_config.d/01-sah-hardening.conf` | Named `01-` so it wins: sshd keeps the first value it reads, and Ubuntu includes `sshd_config.d/*.conf` at the top. `ubuntu` (CI deploys and Lightsail browser SSH) and the named admins that user_data creates (groups `sudo,docker`) are all in `sudo`. `--apply` refuses to run, changing nothing, if any of them is not. The user_data file `99-vc651-hardening.conf` is left in place. |
| Host firewall: input policy drop; allows lo, established/related, `docker0`/`br-*`, tcp 22/80/443, ICMP/ICMPv6, DHCP client | nft `table inet sah_host_fw`, `/etc/nftables/sah-host-fw.nft`, `sah-host-fw.service` | Sits alongside ufw (see below). Only an input chain: Docker-published ports cross FORWARD, so 8000/9000 stay private because they are bound to `127.0.0.1` in `docker/docker-compose.yml`, and `--verify` reports any non-loopback publication as drift. Outbound traffic (RDS, S3, Let's Encrypt, apt) is not filtered. |
| Automatic security updates | `/etc/apt/apt.conf.d/52sah-unattended-upgrades`, `apt-daily*.timer` | unattended-upgrades applies `-security` origins only, daily. It never reboots. Docker Engine and containerd come from download.docker.com, which is not a security origin, so they are never upgraded unattended; patch them by hand in a window. |

**ufw.** Stock Lightsail Ubuntu ships ufw installed but inactive. On this host it is active, because every prod deploy runs `.github/scripts/configure-host-firewall.sh` (VC-647), which allows 22/80/443. ufw lives in the iptables-nft tables `ip filter` / `ip6 filter`, and our table is a separate input base chain, so a packet must be accepted by **both** layers. The script never changes ufw. A deploy that re-enables or reloads ufw leaves our table alone; the container test checks this. `--verify` drifts if ufw is active but missing 22, 80 or 443.

**nftables.service** and `/etc/nftables.conf` are never used. That file starts with `flush ruleset`, which would also wipe ufw's and Docker's rules. `--verify` drifts if that unit is ever enabled.

## Verify (any time, read-only)

Actions → **Harden Lightsail host (prod ERP)** → Run workflow from `main` → `mode = verify`.

The log and the `erp-prod-hardening-evidence-<run>` artifact contain two things:
- the plan an apply would carry out (`--apply --dry-run`: the files it would create or rewrite, with diffs);
- the evidence report: effective `sshd -T`, the nft table, ufw status, listening sockets, published container ports, the unattended-upgrades config and stamps, pending security updates, and whether `/var/run/reboot-required` is set.

Exit codes:
- `0`: OK.
- `2`: drift.
- `3`: unattended-upgrades has not run for more than 3 days, or the dead-man is still armed.

Pending security updates and a required reboot are warnings, not failures. Kernel reboots are manual: Lightsail console → Reboot, in a quiet window. Then check the site and re-run verify.

## Apply (maintenance window)

1. Pick a window with no merge to `main`. A prod deploy rewrites the same Lightsail SSH rule, and doing that during an apply can drop this run's /32. The fresh-connection check then fails and the rollback fires: safe, but the apply is lost.
2. Run `mode = verify` first and read the plan.
3. Run `mode = apply`. The workflow then:
   1. runs `--apply`, which arms a dead-man (`systemd-run --on-active=300`, unit `sah-harden-rollback`) **before** changing anything, then writes the sshd drop-in (`sshd -t` before `systemctl reload ssh`), loads the nft table at runtime, and writes the apt config;
   2. opens a **new** SSH connection and runs `--verify --expect-armed`, then checks that sshd answers a login as `nobody` with `Permission denied` (proof that sshd, not a firewall timeout, answered);
   3. only then, in another invocation, runs `--disarm`, which enables `sah-host-fw.service` (the boot unit) and stops the timer;
   4. runs a final `--verify`.
4. If step 2 fails, the job stops before disarm. Within 5 minutes the timer deletes the nft table, disables the boot unit, removes `01-sah-hardening.conf` and reloads sshd. ufw and the user_data sshd file are untouched. A later `--disarm` refuses, and `--verify` reports `rollback fired`.

By hand on the host, from a session in the `sudo` group:
```bash
sudo bash harden-host.sh --apply --dry-run      # plan only
sudo bash harden-host.sh --apply                # arms the dead-man first
# from a NEW ssh session:
sudo bash harden-host.sh --verify --expect-armed
sudo bash harden-host.sh --disarm
```

## Recovery

- **Locked out within 5 minutes of an apply:** wait. The dead-man undoes the sshd and firewall changes. Then reconnect.
- **Locked out after disarm**, or the timer did not fire:
  1. Use Lightsail browser SSH: console → instance → Connect (`lightsail-connect`, as `ubuntu` with Lightsail's CA certificate). It still works because `ubuntu` is in `sudo` and `TrustedUserCAKeys` is untouched; `--verify` prints it.
  2. Run `sudo bash /usr/local/sbin/sah-harden-rollback.sh` (or `sudo bash harden-host.sh --rollback`).
  3. If browser SSH fails too, there is no console access on Lightsail. Create a new instance from the latest snapshot (AutoSnapshot runs daily at 06:00) and move the static IP to it.
- **Firewall only:** `sudo nft delete table inet sah_host_fw && sudo systemctl disable sah-host-fw.service`.
- **sshd only:** `sudo rm /etc/ssh/sshd_config.d/01-sah-hardening.conf && sudo sshd -t && sudo systemctl reload ssh`.

## Tests

- `bash docker/__tests__/harden-host.test.sh`: the unit layer, run in CI (`deployment-controls.yml`).
- `bash docker/__tests__/harden-host.test.sh --container`: the full apply / verify / dead-man / disarm / rollback cycle. It runs in a privileged, network-isolated `ubuntu:22.04` container with real sshd, nft, iptables-nft, ufw and apt-config. systemd is stubbed.
