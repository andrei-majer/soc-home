# OpenCTI on-demand wake/sleep

OpenCTI (`.22`) runs in on-demand savestate mode since 2026-06-07 — the VM
is normally suspended (frees ~12 GB RAM on the `.15` hypervisor) and woken
only when the TI enrichment/RAG features are needed.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `opencti-wake.sh` | `.20:/usr/local/sbin/` | **Canonical** — resume VM, verify stack, restart TI connectors if cold-boot |
| `opencti-sleep.sh` | `.20:/usr/local/sbin/` | **Canonical** — savestate the VM |
| `opencti-wake.ps1` | `.13:C:\Users\xndre\OneDrive\Claude\soc-lab\` | Thin PowerShell wrapper — SSHes to `.20` and runs `opencti-wake.sh` |
| `opencti-sleep.ps1` | `.13:C:\Users\xndre\OneDrive\Claude\soc-lab\` | Thin PowerShell wrapper — SSHes to `.20` and runs `opencti-sleep.sh` |

## Why split canonical bash + PowerShell wrapper?

The originals were PowerShell on `.13` (Windows workstation) for muscle-memory
reasons — the user runs `.\opencti-wake.ps1` from a Windows terminal. Ported
to bash on `.20` (2026-07-30) so the logic can be scheduled from cron / triggered
from Ansible / run without `.13` being powered on, while keeping the same
Windows entry point.

## Install

**On `.20` (canonical location):**
```bash
sudo install -m 755 -o root -g root opencti-wake.sh opencti-sleep.sh /usr/local/sbin/
```

**On `.13` (Windows wrapper):**
Copy `opencti-wake.ps1` + `opencti-sleep.ps1` to `C:\Users\xndre\OneDrive\Claude\soc-lab\`.

## Usage

```bash
# From .13 (Windows)
.\opencti-wake.ps1                       # wake + verify
.\opencti-sleep.ps1                      # savestate

# From .20 (bash, or any host that can SSH to .20)
sudo /usr/local/sbin/opencti-wake.sh
sudo /usr/local/sbin/opencti-sleep.sh

# From anywhere with SSH access to .20
ssh s /usr/local/sbin/opencti-wake.sh
```

## Prerequisites

- `.20` needs SSH access to:
  - `andrei@192.168.1.15` (VBoxManage on hypervisor) — key at `~/.ssh/id_ed25519`
  - `root@192.168.1.22` (docker on OpenCTI VM) — same key
- If `.15` is ever reinstalled, refresh `.20`'s `~/.ssh/known_hosts` entry
  first or SSH will refuse to connect (host key changed).

## Cold-boot connector fix

On a cold boot from `poweroff` (not savestate resume), the 5 TI connectors +
worker get stuck in a Python retry loop because ES isn't ready when they
first try to reach the platform API. Their Docker containers stay `Up` but
the process inside spins forever, silently. `opencti-wake.sh` detects
`was_cold_boot=1` and `docker restart`s them after the platform HTTP 401
check passes. Also guarded by the Ansible `health-check.yml` connector-
freshness gate as backstop. See memory `soc-lab/opencti-22.md`.
