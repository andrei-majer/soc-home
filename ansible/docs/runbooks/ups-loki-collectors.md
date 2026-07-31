# Runbook — UPS → Loki collectors (Grafana dashboards)

Disaster-recovery + redeploy procedure for the three UPS metric collectors that feed
the Grafana UPS dashboards. None of these hosts converge via `site.yml` (the router is
backup/pull-only, `.13` is Windows, `.15`'s collector predates the role), so the canonical
copies live here and the deploy is manual per host.

## Pipeline

Grafana 12 + Loki run on **.20** (Grafana `:3000`, Loki `:3100` bound `*:3100`). There is no
Prometheus/Influx — metrics travel as **Loki log lines**. Each host runs a small collector that
reads its UPS and POSTs one logfmt line per sample to
`http://192.168.1.20:3100/loki/api/v1/push`, with stream labels:

```
{job="ups", host="<15|1|13>", ups="ted"}
```

logfmt schema (identical across all three hosts):

```
battery_voltage=13.6 input_voltage=235.0 output_voltage=235.0 load=18 temperature=30.8 frequency=50.0 status=OL ol=1 ob=0 lb=0
```

Dashboards query it with `... | logfmt | unwrap <field>` wrapped in
`avg_over_time(... [$__interval])` / `last_over_time(... [$__interval])`.

## Sample cadence — all hosts 30s (smoothness)

The three dashboards are **byte-identical**; graph smoothness is driven purely by sample
density. `.15` samples every **30s** (systemd timer); `.1` and `.13` are on a 1-minute
scheduler (OpenWrt cron / Windows Task Scheduler, both of which have a 60s floor), so to match
`.15`'s smoothness they **push twice per run** — `sample → sleep 30 → sample` — yielding ~30s
spacing without changing the scheduler. (Set 2026-06-29.)

Verify spacing (run on .20):

```sh
for h in 15 1 13; do echo "host=$h:"; curl -s -G "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode "query={job=\"ups\", host=\"$h\"}" --data-urlencode "limit=6" --data-urlencode "since=10m" \
  | jq -r "[.data.result[].values[][0]|tonumber/1e9]|sort|. as \$t|[range(1;length)]|map((\$t[.]-\$t[.-1])|floor)|@csv"; done
```

Healthy: ~30s gaps on all three (~19 samples / 10 min). 60s gaps (~10/10min) ⇒ the double-push
edit reverted on that host.

## .15 hypervisor (Ubuntu) — systemd timer, native 30s

- Collector: `/usr/local/bin/ups-loki-push.sh`, `host="15"`. Reads `upsc ted` (local NUT — see
  `soc-lab/ups-nut-15` memory / NUT config under `/etc/nut`).
- Schedule: systemd `ups-loki.timer` (`OnUnitActiveSec=30s`) → `ups-loki.service`.
- Installer: `setup-ups-loki-15.sh` (needs user sudo). One sample per run (timer already 30s).

## .1 router (OpenWrt R7800) — cron + double-push

- Canonical source: **`roles/suricata/files/ups-loki-push-router-1.sh`** (this repo).
- Live path on router: `/usr/bin/ups-loki-push.sh`. `host="1"`, UPS name `ted`.
- Schedule: `crontab -l` → `* * * * * /usr/bin/ups-loki-push.sh`. The script pushes twice
  (`sample(){...}; sample; sleep 30; sample`) → ~30s spacing.
- BusyBox/ash quirks already handled in the script: `date +%s` + literal `000000000` for the ns
  timestamp (BusyBox `date` has no `%N`); `tr ' ' '_'` to fold spaces in `ups.status`.
- This script is also captured into the (gitignored) router backup set via the openwrt role's
  `openwrt_optional_files` (alongside `soc-watchdog.sh`), so drift is snapshotted on each backup run.

Redeploy (from .13 or .20):

```sh
scp -i ~/.ssh/openwrt roles/suricata/files/ups-loki-push-router-1.sh root@192.168.1.1:/usr/bin/ups-loki-push.sh
ssh -i ~/.ssh/openwrt root@192.168.1.1 "sed -i 's/\r\$//' /usr/bin/ups-loki-push.sh; chmod +x /usr/bin/ups-loki-push.sh"
# (re)install cron if missing:
ssh -i ~/.ssh/openwrt root@192.168.1.1 "crontab -l | grep -q ups-loki-push || (crontab -l; echo '* * * * * /usr/bin/ups-loki-push.sh') | crontab -"
```

CPU cost measured: ~0.11s CPU per 30s window on the R7800 — negligible.

## .13 workstation (Windows) — Scheduled Task + double-push

- Canonical source: **`roles/suricata/files/ups-loki-push-workstation-13.py`** (this repo).
- Live path: `C:\ProgramData\soc-ups\ups-loki-push.py`. `host="13"`.
- The UPS is a Cypress `0665:5161` (Megatec/Q1). Windows' HID stack can't issue the raw
  control+interrupt transfers it needs, so the device is bound to **WinUSB** (one-time, via Zadig)
  and the collector drives it with libusb (pyusb), replicating NUT `nutdrv_qx` 'cypress' framing.
- Deps (global `C:\Python`): `pip install pyusb libusb-package`.
- Schedule: Scheduled Task **`SOC-UPS-13-Loki`**, runs as **SYSTEM**, repetition `PT1M` (60s — the
  Task Scheduler GUI/engine floor; `PT30S` is rejected: "value … out of range"). `main()` loops
  `range(2)` with a 30s sleep → two pushes/run → ~30s spacing.
- Installed via `install-task.ps1` (elevated).

Redeploy (the target dir is SYSTEM-owned — the copy MUST run in an **elevated** PowerShell;
neither Claude Code nor a non-admin shell can write it):

```powershell
# from an elevated PowerShell:
Copy-Item <repo>\roles\suricata\files\ups-loki-push-workstation-13.py C:\ProgramData\soc-ups\ups-loki-push.py -Force
& C:\Python\python.exe C:\ProgramData\soc-ups\ups-loki-push.py --print   # ~30s; pushes two samples
```

`--print` prints parsed values and the logfmt line; errors otherwise log to
`C:\ProgramData\soc-ups\ups-collect.log` and exit 0 (best-effort — never blocks).

## Dashboards (.20)

Provisioned JSON in `/etc/grafana/provisioning/dashboards/{ups-15,ups-router-1,ups-workstation-13}.json`
(provider → folder "SOC Dashboards"). Grafana 12 quirks:
- The file provider does **not** re-scan live — `systemctl restart grafana-server` to pick up a
  changed/new dashboard.
- Provisioned dashboards are stored in **unified storage** (`resource` table), not the legacy
  `dashboard` table.

The dashboard JSON is not yet tracked in this repo (lives only on .20). If you want full DR for
the panels too, capture the three files into `roles/suricata/files/` and add a provisioning task.

## Night gap

`.20` (Grafana + Loki, a VM on `.15`) sleeps 23:00–06:00 with the SOC VMs, so collection/viewing
pauses overnight. Collectors keep firing and just fail their push (log + exit 0) while Loki is down.
