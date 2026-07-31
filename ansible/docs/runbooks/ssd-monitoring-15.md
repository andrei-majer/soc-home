# Runbook — SSD SMART monitoring on .15

Disaster-recovery + redeploy for the .15 hypervisor SSD health monitoring: a Loki
metrics collector (Grafana trending) + `smartd` self-tests and threshold alerts to
Telegram. `.15` is not Ansible-managed (runs the VBox host), so the canonical scripts
live here and the deploy is a single root installer.

## What it does

.15 has two SATA SSDs (no NVMe): **sda = Crucial MX300 525 GB** (OS root + `/mnt/storage`),
**sdb = Crucial MX500 250 GB** (`/mnt/vms`). Baseline + attribute meanings: `soc-lab/ssd-health-15` memory.

- **Loki collector** `/usr/local/bin/ssd-smart-loki-push.sh` + systemd `ssd-smart-loki.timer`
  (every 10 min). Pushes one logfmt line/device to Loki `.20:3100`, labels
  `{job="ssd", host="15", dev=<sda|sdb>, model=...}`:
  `health life_remaining_pct life_used_pct erase_count temp_c tbw_tb reallocated
  realloc_events pending uncorrectable reported_uncorrect power_on_hours power_cycles`.
  Same pattern as the UPS collectors ([[ups-nut-15]] / `ups-loki-collectors.md`).
- **smartd** (`smartmontools.service`) — both devices, weekly SHORT self-test **Sun 12:00**
  (inside the 06:00–23:00 awake window; `soc-sleep` suspends the host 23:00–06:00), temp watch
  `-W 4,60,70` (delta 4 °C / info 60 / critical 70 — sda historically peaked 78 °C).
- **Alerts → Telegram** via `/usr/local/bin/smartd-telegram.sh` (smartd `-M exec`). Bot creds
  are read from **`/etc/default/smartd-telegram`** (root 0600, NOT tracked). Same bot as the
  rest of the SOC alerting (migrated off ntfy 2026-06-29).

## Files (tracked in this repo)

- `roles/suricata/files/ssd-smart-loki-push.sh`   → `/usr/local/bin/` (collector)
- `roles/suricata/files/smartd-telegram.sh`       → `/usr/local/bin/` (smartd notifier)
- `roles/suricata/files/install-ssd-monitoring-15.sh` (the installer below)

Not tracked (secrets / host state): `/etc/default/smartd-telegram`, `/etc/smartmontools/smartd.conf`,
the two systemd units (all written by the installer).

## Deploy / redeploy

`smartmontools` must be installed first (`sudo apt-get install -y smartmontools`). Then, from `.13`:

```bash
scp -i ~/.ssh/openwrt roles/suricata/files/ssd-smart-loki-push.sh \
    roles/suricata/files/smartd-telegram.sh \
    roles/suricata/files/install-ssd-monitoring-15.sh andrei@192.168.1.15:/tmp/
ssh -i ~/.ssh/openwrt andrei@192.168.1.15
cd /tmp && sed -i 's/\r//g' *.sh
# first install — pass the Telegram bot creds (written to /etc/default/smartd-telegram 0600):
sudo TG_TOKEN='<bot-token>' TG_CHAT='<chat-id>' bash install-ssd-monitoring-15.sh
# re-run later (config/script change) — creds reused if the env vars are omitted:
sudo bash install-ssd-monitoring-15.sh
```

Creds: the SOC Telegram bot (`@bm_home1_bot`, chat `638482812`) — token in soc-ansible vault
`vault_telegram_bot_token`, or BotFather. Sudo on .15 is the rotated password ([[infrastructure]]),
not stored.

## Verify

```bash
# collector landing in Loki (run on .20):
curl -s -G http://localhost:3100/loki/api/v1/query --data-urlencode \
  'query=count_over_time({job="ssd", host="15"}[20m])' | jq -r '.data.result[].value[1]'
# smartd:
systemctl status smartmontools ssd-smart-loki.timer
sudo smartctl -a /dev/sda    # Percent_Lifetime_Remain (202), Total_LBAs_Written (246)
# fire a Telegram test by hand:
sudo SMARTD_DEVICESTRING=/dev/sda SMARTD_MESSAGE="manual test" SMARTD_FAILTYPE=TEST /usr/local/bin/smartd-telegram.sh
```

## Grafana dashboard

Provisioned on `.20`: **`SSD Health — Hypervisor .15`** (uid `ssd-health-15`,
`http://192.168.1.20:3000/d/ssd-health-15/`). 10 panels: per-drive life-remaining %, temp,
reallocated stats + life/temp/TBW/error-sector trends. Source tracked at
`roles/suricata/files/ssd-15.json` → deploy to `/etc/grafana/provisioning/dashboards/ssd-15.json`
(`root:grafana 0640`) then `systemctl restart grafana-server` (Grafana 12 file provider does not
re-scan live; stores in the `resource` unified-storage table).

## Notes

- Night gap: `.20` (Loki) and `.15` both sleep 23:00–06:00, so collection pauses overnight —
  the weekly self-test is scheduled at noon to land while awake.
- `smartd -m root` is a placeholder (no MTA on .15); the `-M exec` Telegram script is what fires.
