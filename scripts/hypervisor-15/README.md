# Hypervisor `.15` — SOC VM sleep/wake automation

Replaces the Windows Task Scheduler `SOC-Sleep` / `SOC-ResumeVMs` jobs that
ran on the pre-2026-06-08 Windows hypervisor. systemd timers do the same job
on the new Ubuntu 24.04 host: ACPI-shutdown the SOC VMs at 23:00 local
(Bucharest), cold-boot them at 06:00. Logs go to journal.

**Now Ansible-managed** — see `ansible/roles/hypervisor/tasks/main.yml`
(added 2026-07-16). This directory remains the canonical source for the
script/unit content the role copies from.

## Files

| File | Install path on `.15` | Purpose |
|---|---|---|
| `soc-sleep.sh` | `/usr/local/bin/` (mode 755, root:root) | ACPI shutdown each running SOC VM; force-poweroff after 5 min timeout |
| `soc-wake.sh` | `/usr/local/bin/` (mode 755, root:root) | `VBoxManage startvm --type headless` for each VM; ping verify with one auto-reset retry |
| `soc-sleep.service` | `/etc/systemd/system/` | Oneshot, `User=andrei`, runs `soc-sleep.sh` |
| `soc-sleep.timer` | `/etc/systemd/system/` | `OnCalendar=*-*-* 23:00:00 Persistent=true` |
| `soc-wake.service` | `/etc/systemd/system/` | Oneshot, `User=andrei`, runs `soc-wake.sh` |
| `soc-wake.timer` | `/etc/systemd/system/` | `OnCalendar=*-*-* 06:00:00 Persistent=true` |
| `soc-vm-shutdown.sh` | `/usr/local/bin/` (mode 755, root:root) | ACPI shutdown of **every** running VM; force-poweroff after 180s |
| `soc-vm-shutdown.service` | `/etc/systemd/system/` | `ExecStop`-only unit; systemd runs it before `vboxdrv` on reboot/poweroff |
| `99-span-nic.yaml` | `/etc/netplan/` (mode 600, root:root) | Keeps the SPAN NIC `enp4s0` address-less |

## Clean guest shutdown on host reboot (`soc-vm-shutdown`)

A plain `reboot` of `.15` kills the `VBoxHeadless` processes outright, so every guest
lands in VBox state `aborted` — the equivalent of yanking its power. Confirmed
2026-08-23: after an operator reboot, `soc-sleep` logged
`skip ELK / T-Pot Hive / OpenCanary (state=aborted)`. Elasticsearch and T-Pot's 24
containers both recovered that time, but it is an index-corruption path on every reboot.

`soc-vm-shutdown.service` does nothing on start (`ExecStart=/bin/true`,
`RemainAfterExit=yes`); it exists purely for its `ExecStop`. Because it declares
`After=vboxdrv.service`, systemd stops it **before** `vboxdrv` on the way down, which is
when the guests get their ACPI power button and up to 180s to flush.

It covers **all** running VMs, not just the autostart-flagged ones — `T-Pot Hive` is
started by `soc-wake`, not by `vboxautostart`, and needs a clean stop too.

VirtualBox's own `SHUTDOWN_USERS` / `SHUTDOWN=acpibutton` hook in
`/etc/default/virtualbox` was rejected for this: `stop_vms()` in `vboxdrv.sh` waits a
hardcoded 30s before unloading the module, far too short for ELK or T-Pot Hive, so they
would still be killed mid-shutdown — the failure would just move later.

Ad-hoc clean stop of the whole fleet (e.g. before pulling power):

```bash
sudo systemctl stop soc-vm-shutdown.service     # runs the ExecStop
sudo systemctl start soc-vm-shutdown.service    # re-arm afterwards
```

## Why `soc-sleep.sh` has a window guard

Both timers carry `Persistent=true`, so a host boot outside 23:00–06:00 replays **both**
missed schedules seconds apart. On 2026-08-23 `soc-sleep` and `soc-wake` both fired at
08:12:59 — wake won only because it started one second later, and sleep no-op'd solely
because the VMs happened to be `aborted`. On a clean boot, sleep would ACPI-down exactly
what wake had just started.

`soc-sleep.sh` therefore no-ops outside 23:00–06:00 unless passed `--force`.

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
netplan entry, `enp4s0` stays DOWN at boot and Suricata sees nothing — and
with a half-explicit one it comes up but accepts router advertisements, so
the host starts transmitting onto the mirror it is supposed to be passively
watching.

Ship `99-span-nic.yaml` to `/etc/netplan/` (mode 600 root:root), then:

```bash
sudo netplan generate && sudo netplan apply
sudo ip -6 addr flush dev enp4s0 scope global   # drop addresses already learned via RA
```

The interface comes up admin-UP without an IP; VirtualBox bridges into it
directly. (`optional: true` keeps boot from hanging if the cable is unplugged.)

⚠ The original of this file lived in `/etc/netplan/99-static-ip.yaml`, which did
**not** survive the 2026-07-02 encrypted-RAID1 reinstall — only
`50-cloud-init.yaml` came back, and by 2026-08-23 `enp4s0` was holding two global
IPv6 addresses. It is a separate file now, and Ansible-managed, so a reinstall
cannot silently lose it again. `eno1`'s static `192.168.1.15/24` still comes from
`50-cloud-init.yaml` and is deliberately not mentioned here.

## VMs covered

`ELK` (.21), `T-Pot Hive` (.23), `OpenCanary` (.24).

`Suricata` (.20) is **deliberately excluded since 2026-07-16** — it hosts Grafana
and stays up 24/7 instead of cycling nightly. (Mobile access to that Grafana went
via a `grafana-proxy` container on `.15` until 2026-08-01; that proxy is **retired**
— `.20` joined the tailnet itself, so the phone now reaches `100.66.251.41:3000`
directly under the `tag:mobile -> tag:soc` grant. See memory `soc-lab/tailscale.md`.)

`OpenCTi` is **deliberately excluded** — it runs in on-demand savestate mode
since 2026-06-07 (woken manually via `opencti-wake.ps1` on `.13` when needed).
`OpenClaw` and the retired `T-Pot Sensor` are not SOC services. Both were archived
to `/mnt/cold` on 2026-08-22 and **unregistered from VirtualBox on 2026-08-23** —
their files are intact, but leaving them registered on a late-unlocking LUKS volume
broke `vboxautostart` on every boot. See "VM registry and the `/mnt/cold` ordering"
below before re-registering either.

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

## Suricata boot-recovery + watchdog (added 2026-07-29)

After a `.15` reboot for a RAM upgrade, Suricata stayed down until noticed
manually — `soc-wake.timer` excludes it (deliberate; see above) and there was
no VBox autostart, so nothing brought it back. Two defenses:

| File | Install path on `.15` | Purpose |
|---|---|---|
| `suricata-vm-start.service` | `/etc/systemd/system/` (644 root:root) | Cold-starts the Suricata VM at host boot as `andrei`. `After=vboxdrv.service systemd-modules-load.service`, `ExecStartPre` polls `/dev/vboxdrv` for 60s (same race that bit `soc-wake.sh`), `KillMode=process` so VBoxHeadless survives oneshot exit. `ExecStop=controlvm ... acpipowerbutton`. |
| `suricata-watchdog.sh` | `/home/andrei/suricata/` (755 andrei:andrei) | Andrei crontab `*/5 * * * *`. Checks `VBoxManage list runningvms`; sends one Telegram alert + re-alerts every 3h while broken, plus a recovery message when VM returns. Reuses `~/teslamate/.telegram.env` (**note: `TG_TOKEN` / `TG_CHAT`, not the generic `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`**). Logs to `watchdog.log` in the same dir, state in `watchdog.state`. |

```bash
sudo install -m 644 -o root -g root suricata-vm-start.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable suricata-vm-start.service
# Do NOT start now — VM is already running; enable fires at next boot only.

sudo -u andrei mkdir -p /home/andrei/suricata
sudo install -m 755 -o andrei -g andrei suricata-watchdog.sh /home/andrei/suricata/
sudo -u andrei bash -c '(crontab -l 2>/dev/null; echo "*/5 * * * * /home/andrei/suricata/suricata-watchdog.sh") | crontab -'
```

**Coverage gap (deliberate):** neither defense catches "VM up but Suricata
process dead" nor "SPAN NIC carrier lost." Adding that would need SSH
`.15`→`.20` keys wired up and an `eve.json`-mtime probe in the watchdog.

## See also

- [`hypervisor-15` memory](https://github.com/andrei-majer/soc-home) — full migration history
- The old Windows scripts are gone with the OS; this directory is the
  equivalent in Linux idiom

## VM registry and the `/mnt/cold` ordering

`VBoxSVC` caches each machine's accessibility **once, at startup**. If a registered VM's config
lives on a volume that is not mounted yet, that VM is inaccessible for the life of that VBoxSVC —
and `VBoxAutostart`, which enumerates **all** registered machines, aborts the entire run with
`E_ACCESSDENIED` (component `MachineWrap`, interface `IMachine`), starting **nothing** while still
exiting `0`. Silent SOC outage.

That is exactly what happened on 2026-08-23: `OpenClaw` and `T-Pot Sensor` had been archived to
`/mnt/cold` (a late-unlocking LUKS volume) on Aug 22, and every boot after that came back with only
Suricata running.

Two independent defences are now in place, and both should stay:

1. **Mount ordering** on every unit that can spawn VBoxSVC — `vboxautostart-service` (drop-in),
   `suricata-vm-start`, `soc-wake`, `soc-vm-shutdown`:
   `RequiresMountsFor=/mnt/vms` plus a plain `After=mnt-cold.mount`.
   `/mnt/cold` is **ordering-only on purpose** — making it a hard requirement would turn an archive
   volume into a single point of failure for the live fleet.
2. **The archived VMs are unregistered** (`unregistervm`, no `--delete` — files intact on
   `/mnt/cold/vm-archive/`). Registry holds 5 VMs: ELK, OpenCanary, OpenCTi, Suricata, T-Pot Hive.

⚠ **Registering a VM whose files live on `/mnt/cold` re-arms this failure mode.** Defence 1 is what
then keeps it safe. If you ever add one, verify a cold boot before trusting it.

⚠ Diagnosing it again: an inaccessible VM has no usable name, so `VBoxManage showvminfo "<name>"`
returns `VBOX_E_OBJECT_NOT_FOUND` while `VBoxManage list vms` still lists it. That mismatch is the
tell — query by UUID to inspect it. Note also that `vboxautostart.log` is only written by
`--background` runs; interactive runs log to stdout and leave the file stale.
