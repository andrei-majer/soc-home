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

**SPAN NIC at boot.** The Suricata VM bridges its 2nd adapter to `enp4s0`
(the Realtek port carrying the switch's SPAN mirror). Without an explicit
netplan entry, `enp4s0` stays DOWN at boot and Suricata sees nothing.
Append to `/etc/netplan/99-static-ip.yaml`:

```yaml
    enp4s0:
      dhcp4: no
      dhcp6: no
      optional: true
      link-local: []
      accept-ra: false
```

Then `sudo netplan apply`. The interface comes up admin-UP without an IP;
VirtualBox bridges into it directly. (`optional: true` keeps boot from
hanging if the cable is unplugged.)

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

## Docker storage guardrails (added 2026-07-06)

`.15` runs TeslaMate in Docker and is used for ad-hoc image testing, which
repeatedly filled the 98 GB root. Docker's data was relocated onto `/mnt/vms`
(daemon `data-root` **and** the system containerd `--root`, since this host uses
the containerd snapshotter — image bulk lives in `/var/lib/containerd`, not
`/var/lib/docker`). These two units keep it bounded:

| File | Install path on `.15` | Purpose |
|---|---|---|
| `docker-prune.sh` | `/usr/local/sbin/` (755) | Prune unused images / build cache / stopped containers **older than 7d**; never volumes |
| `docker-prune.service` + `.timer` | `/etc/systemd/system/` | Oneshot, weekly `OnCalendar=Sun 07:00 Persistent=true` |
| `disk-alert.sh` | `/usr/local/sbin/` (755) | Telegram alert when `/` or `/mnt/vms` ≥ 85% (one alert per crossing, `/run` flag files); reuses `/etc/default/smartd-telegram` creds |
| `disk-alert.service` + `.timer` | `/etc/systemd/system/` | Oneshot, `OnCalendar=hourly Persistent=true` |

```bash
sudo install -m 755 -o root -g root docker-prune.sh disk-alert.sh /usr/local/sbin/
sudo install -m 644 -o root -g root docker-prune.{service,timer} disk-alert.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-prune.timer disk-alert.timer
```

## See also

- [`hypervisor-15` memory](https://github.com/andrei-majer/soc-home) — full migration history
- The old Windows scripts are gone with the OS; this directory is the
  equivalent in Linux idiom
