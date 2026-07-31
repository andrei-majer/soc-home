# Runbook: Windows Hypervisor (192.168.1.15)

Windows 11 Pro VirtualBox host running the SOC lab VMs. NOT managed by Ansible.

## Host Overview

| Field | Value |
|---|---|
| Hostname | (Games workstation) |
| IP | 192.168.1.15 |
| OS | Windows 11 Pro |
| User | `Games` / `Mamamia` |
| MAC | `B4:2E:99:34:9C:6B` |
| Hardware | Intel i7-9700K, 64 GB RAM |
| Role | VirtualBox 7.2.6r172322 host for all SOC lab VMs |

## VBoxManage

**VBoxManage is NOT in PATH.** Always use the full path:

```
"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
```

## VM Inventory

| VM | IP | Role |
|---|---|---|
| Suricata | 192.168.1.20 | IDS / Ansible control node |
| ELK | 192.168.1.21 | Elastic + Wazuh + MISP + Kibana |
| T-Pot Hive | 192.168.1.23 | Honeypot aggregator |
| T-Pot Sensor | 192.168.1.125 | Honeypot sensor |
| OpenCTI | 192.168.1.22 | CTI platform |

## Important: VM Ownership

VMs are registered under the **Games** user account. Any Task Scheduler task that touches VBoxManage **MUST run as `Games`** (not SYSTEM) — SYSTEM cannot see VMs registered to another user and VBoxManage will return an empty list.

## Scripts (C:\scripts\)

| Script | Purpose |
|---|---|
| `soc-sleep-savestate.ps1` | Savestate VMs for nightly pause. T-Pot Sensor and T-Pot Hive get **ACPI poweroff instead** — savestate breaks Docker networking and causes severe VirtualBox timer lag on Hive |
| `soc-start-savestate.ps1` | Resume from saved state, cold-start anything not saved |
| `soc-start-vms.ps1` | Start all VMs headless, skip those already running |
| `soc-stop-vms.ps1` | ACPI shutdown in reverse dependency order, does **not** power off the host |

Logs: `C:\scripts\soc-*.log`.

## Task Scheduler

| Task | Trigger | Script |
|---|---|---|
| SOC-Sleep | Daily 23:00 | `soc-sleep-savestate.ps1` |
| SOC-ResumeVMs | Daily 06:00 | `soc-start-savestate.ps1` |
| SOC-StartVMs | On boot | `soc-start-savestate.ps1` |

All tasks run as user `Games`.

## T-Pot Gotchas

- **Hive savestate resume** produces 600+ seconds of VirtualBox timer lag; VMs are unusable. Hive now uses **ACPI poweroff** on sleep.
- **Sensor network** may not come up after a forced poweroff. Symptom: phantom Docker containers, no bridge.
- **Console access via VRDE** (port 3390):
  ```
  "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm "T-Pot Sensor" vrde on --vrde-port 3390
  ```
  Then RDP to `192.168.1.15:3390`.

## HVCI / VBS (MUST stay disabled)

Disabled **2026-03-29** along with WSL and VirtualMachinePlatform.

**Result:** CPU 72% to 4%, power draw 69 W to 30 W, native VT-x restored. This is what makes VirtualBox usable on this host — **never re-enable**.

**Verify RAPL power draw:**
```
Get-Counter "\Energy Meter(rapl_package0_pkg)\Power"
```
Returns mW. Expect ~30 W idle.

Power plan: **Balanced**.

## Wake-on-LAN

MAC: `B4:2E:99:34:9C:6B`.

Manual wake from router:
```
ssh root@192.168.1.1 "etherwake -i br-lan B4:2E:99:34:9C:6B"
```

Normally unnecessary — host runs 24/7 since 2026-04-07.

## Rebuild From Scratch

1. **Install Windows 11 Pro**, create local user `Games` with password `Mamamia`.
2. **Install VirtualBox 7.2.6r172322** + Extension Pack. Do NOT add VBoxManage to PATH.
3. **Disable HVCI / VBS / WSL / VirtualMachinePlatform** (see `windows-hvci-optimization-workflow.md`). Reboot. Verify with `Get-Counter` RAPL.
4. **Restore VM registrations** under the Games account (import `.vbox` files or reattach existing VDIs).
5. **Deploy `C:\scripts\`** with the four `soc-*.ps1` scripts.
6. **Create Task Scheduler tasks** (SOC-Sleep, SOC-ResumeVMs, SOC-StartVMs) — all must run as `Games`, not SYSTEM.
7. **Verify**: `soc-start-vms.ps1` boots all 5 VMs, `ping 192.168.1.20 133 130 125 135` all respond.
