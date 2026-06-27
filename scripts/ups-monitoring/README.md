# UPS monitoring & power-loss resilience (NUT + Loki + Grafana)

Two small line-interactive UPSes (Cypress `0665:5161`, Megatec/**Q1** protocol) protect the
lab, each monitored by **NUT** (`nutdrv_qx`). Readings are shipped to **Loki** and graphed in
**Grafana**. The hypervisor additionally rides out outages by **suspending to RAM** instead of
shutting down; the router is monitor-only.

```
 UPS (USB 0665:5161) ── NUT (nutdrv_qx, protocol=Q1) ──> upsc
        │                                                  │
   hypervisor-15                                       per-host collector
   resilience loop                                     (logfmt push) ──> Loki (.120:3100)
   (suspend / poll / shutdown)                                              │
   router-1: monitor-only                                              Grafana dashboards
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

## grafana/ — dashboards
Provisioned Grafana dashboards (drop into `/etc/grafana/provisioning/dashboards/`). No
Prometheus in the lab, so metrics travel as Loki log lines; panels use
`| logfmt FIELD | unwrap FIELD`.

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
