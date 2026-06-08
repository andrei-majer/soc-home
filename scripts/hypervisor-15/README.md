# Hypervisor `.15` — SOC VM sleep/wake automation

Replaces the Windows Task Scheduler `SOC-Sleep` / `SOC-ResumeVMs` jobs that
ran on the pre-2026-06-08 Windows hypervisor. systemd timers do the same job
on the new Ubuntu 24.04 host: ACPI-shutdown 4 SOC VMs at 23:00 local
(Bucharest), cold-boot them at 06:00. Logs go to journal.

## Files

| File | Install path on `.15` | Purpose |
|---|---|---|
| `soc-sleep.sh` | `/usr/local/bin/` (mode 755, root:root) | ACPI shutdown each running SOC VM; force-poweroff after 5 min timeout |
| `soc-wake.sh` | `/usr/local/bin/` (mode 755, root:root) | `VBoxManage startvm --type headless` for each VM; ping verify with one auto-reset retry |
| `soc-sleep.service` | `/etc/systemd/system/` | Oneshot, `User=andrei`, runs `soc-sleep.sh` |
| `soc-sleep.timer` | `/etc/systemd/system/` | `OnCalendar=*-*-* 23:00:00 Persistent=true` |
| `soc-wake.service` | `/etc/systemd/system/` | Oneshot, `User=andrei`, runs `soc-wake.sh` |
| `soc-wake.timer` | `/etc/systemd/system/` | `OnCalendar=*-*-* 06:00:00 Persistent=true` |

## Install

```bash
# Copy:
sudo install -m 755 -o root -g root soc-sleep.sh soc-wake.sh /usr/local/bin/
sudo install -m 644 -o root -g root soc-sleep.service soc-sleep.timer soc-wake.service soc-wake.timer /etc/systemd/system/

# Enable:
sudo systemctl daemon-reload
sudo systemctl enable --now soc-sleep.timer soc-wake.timer

# Verify:
systemctl list-timers soc-sleep.timer soc-wake.timer
```

**Timezone:** the host must be on `Europe/Bucharest` (or whatever local time
you want `OnCalendar=*-*-* HH:MM:SS` to refer to). On a fresh Ubuntu cloud
image the default is UTC, which puts `23:00:00` at 02:00 local — set with
`sudo timedatectl set-timezone Europe/Bucharest`.

## VMs covered

`Suricata` (.120), `ELK` (.133), `T-Pot Hive` (.130), `OpenCanary` (.140).
`OpenCTi` is **deliberately excluded** — it runs in on-demand savestate mode
since 2026-06-07 (woken manually via `opencti-wake.ps1` on `.13` when needed).
`OpenClaw` and the retired `T-Pot Sensor` are not SOC services and stay off.

## Why ACPI shutdown (not savestate)

ACPI cold-boot is what the pre-migration Windows scripts actually did
(despite their misleading `*-savestate.ps1` names). It avoids:

- 40+ GB of nightly RAM-to-disk writes
- T-Pot Hive's documented 600s+ savestate-resume timer lag
- Post-savestate clock-skew weirdness

It does exercise the cold-boot path nightly — which is good, because it
keeps the `Restart=on-failure` hardening on `wazuh-manager` honest and
catches any new startup race the morning after deploying it, not weeks later
during an outage.

## Manual control

```bash
# Run now (one-shot):
sudo systemctl start soc-sleep.service
sudo systemctl start soc-wake.service

# Tail live:
journalctl -u soc-sleep.service -f
journalctl -u soc-wake.service -f

# Disable temporarily:
sudo systemctl stop soc-sleep.timer soc-wake.timer
```

## See also

- [`hypervisor-15` memory](https://github.com/andrei-majer/soc-home) — full migration history
- The old Windows scripts are gone with the OS; this directory is the
  equivalent in Linux idiom
