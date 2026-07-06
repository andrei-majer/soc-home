# `hypervisor` role — `.15` host stack

Brings the `.15` (Ubuntu 24.04) hypervisor **host** configuration under Ansible.
Runs against the `hypervisor` inventory group with `become: true`.

> **Context:** `.15` was previously runbook-only (the removed "Play 7" in
> `playbooks/site.yml`). That worked until the 2026-07-02 encrypted-RAID1
> reinstall silently dropped the `ups-loki` collector — the `ups-hyper-15`
> Grafana dashboard went blank until it was manually restored. This role exists
> so host-side units survive a rebuild via `ansible-playbook`.

## Scope

| Managed | Notes |
|---|---|
| `docker-prune.{sh,service,timer}` | Weekly prune of unused images/cache/stopped containers >7d; never volumes |
| `disk-alert.{sh,service,timer}` | Hourly Telegram alert when `/` or `/mnt/vms` ≥ 85% (reads token from `/etc/default/smartd-telegram`) |
| `eno1-disable-offload.service` | Disables `eno1` TSO/GSO/GRO at boot — mitigates the Intel I219-V `e1000e` **"Detected Hardware Unit Hang"** that dropped `.15` off the LAN on 2026-07-06 (829 hangs; OS stayed up, NIC dead). Also ensures `ethtool` is installed. |

Idempotent — these are already deployed on `.15`; the role just codifies them.

## Not managed here
- The runtime `/etc/nut/ARMED` toggle — operator-controlled on purpose.

## Planned next passes
`ups-loki`, `ssd-smart-loki`, `soc-sleep`/`soc-wake`, `lm-sensors`, and the NUT
config (`ups.conf`/`upsmon`/`upssched`/`ups-resilience` + `upsd.users` — the last
needs `ansible-vault`). Source copies live under `../../scripts/hypervisor-15/`
and `../../scripts/ups-monitoring/hypervisor-15/`.

## Run
```bash
ansible-playbook playbooks/site.yml --limit hypervisor-15 --check   # dry run
ansible-playbook playbooks/site.yml --limit hypervisor-15           # apply
```
