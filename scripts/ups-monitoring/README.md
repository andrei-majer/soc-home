# UPS monitoring & power-loss resilience (NUT + Loki + Grafana)

Three small line-interactive UPSes (Cypress `0665:5161`, Megatec/**Q1** protocol) protect the
lab. The two on Linux hosts are monitored by **NUT** (`nutdrv_qx`); the Windows workstation
talks to its UPS over **WinUSB + pyusb** (the Windows HID stack can't issue the raw USB
transfers the Cypress firmware needs — see `workstation-13/`). Readings are shipped to **Loki**
and graphed in **Grafana**. The hypervisor additionally rides out outages by **suspending to
RAM** instead of shutting down; the router and workstation are monitor-only.

```
 UPS (USB 0665:5161) ──> Megatec/Q1 over USB ──────────────> one logfmt line/sample
        │                                                            │
   hypervisor-15  NUT nutdrv_qx + resilience loop (suspend)          │
   router-1       NUT nutdrv_qx (monitor-only)            ──> per-host collector ──> Loki
   workstation-13 WinUSB + pyusb (monitor-only)                 (.20:3100)    │
                                                                          Grafana dashboards
```

## Why `protocol = Q1`
`nutdrv_qx` blind-probes ~10 sub-protocols. These UPSes only answer `Q1`, so autodetect takes
~36 s (every other probe burns a 1 s timeout) — long enough to trip systemd's driver start
timeout ("driver exited abnormally"). Pinning `protocol = Q1` makes the driver connect in ~1 s.

## hypervisor-15/ — resilient host (suspend, don't shut down)
The hypervisor runs the SOC VMs, so on mains loss it **suspends to S3** (host + VMs freeze at
~5 W) and wakes via RTC every 3 min to re-check the UPS:

* mains restored → stay up;
* still on battery, healthy → suspend again;
* **battery low** → graceful VM stop (`soc-sleep.service`) then `poweroff`.

This survives long outages on a small battery and resumes instantly when power returns.

* `ups-resilience.sh` / `.service` — the suspend/poll/shutdown controller (DRY-RUN unless
  `/etc/nut/ARMED` exists). Triggered on `ONBATT` via `upssched`.
* `nut/` — NUT config. **`upsmon`'s own `SHUTDOWNCMD` is deliberately a no-op `logger`** so it
  cannot race the resilience loop (its forced-shutdown otherwise fires on stale state across a
  suspend and powers the host off after a clean resume). The resilience loop is the sole
  shutdown authority.
* `sudoers.d/nut-shutdown` — lets the unprivileged `nut` user start only the resilience service.
* `ups-loki-push.sh` / `.service` / `.timer` — 30 s metrics push to Loki.

**Arm with** `sudo touch /etc/nut/ARMED` (after testing in dry-run). Requires S3 suspend/resume
to work on the host (verify with `rtcwake -m no -s 45 && systemctl suspend`).

## router-1/ — monitor-only edge (OpenWrt)
The router can't sleep or shut down, so NUT here is pure observability. NUT on OpenWrt is
UCI-driven (`/etc/config/nut_server`); the `protocol = Q1` override uses the init script's
generic `list other` pass-through. A 1-minute cron job pushes readings to Loki.

> The router flipping to **`OB` (on battery) is the earliest whole-house mains-loss signal** —
> it loses power before anything behind it does.

### Power-outage alerts (Telegram)
The router is also the right place to **alert on the outage itself**: it rides the outage on its own
UPS and is the internet gateway (the hypervisor suspends and the SOC VMs go with it, so they can't
report their own power loss). OpenWrt ships no `upsmon` here, so alerting is a tiny cron-driven
transition detector rather than a `NOTIFYCMD` hook.

* `ups-telegram-notify.sh` — install at `/usr/local/bin/`, run every minute (see `crontab.snippet`).
  Reads `upsc ted ups.status`, compares to the last state, and on a change sends **one** Telegram
  message: 🔴 *POWER LOST* on `OL → OB`, 🟢 *POWER RESTORED* on `OB → OL`. The first run after a
  reboot just baselines (no alert).
* **WAN resilience:** a send that fails (e.g. a transient uplink blip, or the ISP's own upstream
  going dark) is appended to a queue and retried every run, so the *POWER LOST* alert still
  arrives — with its original timestamp — once connectivity returns. When the router *and* the
  upstream network gear are on UPS, the alert is delivered in real time.
* `ups-telegram.conf.example` — copy to `/etc/ups-telegram.conf` (chmod 600) and fill in the bot
  token + chat id. No token ever lives in the script itself.

## workstation-13/ — Windows workstation (WinUSB + pyusb)
The third UPS hangs off the Windows workstation. Same Cypress `0665:5161` chip, but on Windows
it enumerates as a *vendor-defined HID* and Windows can't read it as a battery. NUT's
`nutdrv_qx` drives these by issuing **raw 8-byte USB control (`Set_Report`) + interrupt-IN
reads** — exactly what the Windows **HID** stack refuses to do (it forces full 65-byte reports,
so the firmware never answers). The fix is to bind *just this device* to **WinUSB** (one-time,
via Zadig, reversible in Device Manager) and talk to it with **libusb/pyusb**, replicating the
`nutdrv_qx` *cypress* subdriver framing. A small Python collector then parses `Q1` and pushes
the same logfmt line as the Linux hosts.

* `ups-loki-push.py` — pyusb collector (cypress framing + Megatec `Q1` parse → Loki, `host="13"`).
  `python ups-loki-push.py --print` to test; no args = push one sample.
* `install-task.ps1` — deploys the collector to `%ProgramData%\soc-ups\` and registers a
  scheduled task (every minute). The SYSTEM/at-boot variant needs elevation; a per-user
  at-logon variant runs without it.

**One-time bind:** Zadig → *Options ▸ List All Devices* → pick USB ID **`0665 5161`**
("RICHCOMM UPS USB Mon V2.0") → target **WinUSB** → *Replace Driver*. Deps: `pip install
pyusb libusb-package`.

## Grafana dashboards
The three UPS dashboards are **Ansible-managed** alongside the other SOC dashboards in
`ansible/roles/suricata/files/` (`ups-15.json`, `ups-router-1.json`, `ups-workstation-13.json`),
deployed to `/etc/grafana/provisioning/dashboards/` by the `suricata` role. No Prometheus in the
lab, so metrics travel as Loki log lines; panels use `| logfmt FIELD | unwrap FIELD`.

> **LogQL note:** extract *only* the field you unwrap (`| logfmt load | unwrap load`). A bare
> `| logfmt | unwrap load` promotes every reading (voltages, frequency…) to a label, so each
> sample becomes its own series — dozens of fragmented duplicates.

> **Grafana 12:** the file provider does not hot-reload — `systemctl restart grafana-server` to
> pick up a new/changed dashboard. Provisioned dashboards live in unified storage (the
> `resource` table), not the legacy `dashboard` table.

## Secrets
`nut/upsd.users` and `nut/upsmon.conf` contain `CHANGEME` placeholders for the local
`monuser` password (used only between `upsd` and `upsmon` on `127.0.0.1`). Set a real value in
both before use.

`router-1/ups-telegram.conf.example` carries `CHANGEME` placeholders for the Telegram bot token
and chat id — copy to `/etc/ups-telegram.conf` (mode 600) and set real values. The notifier
script sources them at runtime; no token is ever embedded in the script.
