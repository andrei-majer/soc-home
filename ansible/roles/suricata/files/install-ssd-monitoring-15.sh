#!/usr/bin/env bash
# Install SSD + RAID health monitoring on the .15 hypervisor:
#   - Loki collector (systemd timer, every 10 min) -> Grafana on .20
#       * per-disk SMART (Crucial + ADATA SU800 families; per-model attr maps)
#       * md RAID array state (degraded / sync), labelled by /dev/md/<name>
#   - smartd weekly SHORT self-test + temperature watch -> Telegram alerts
#   - mdadm --monitor PROGRAM hook -> Telegram on RAID array events
#
# Topology since 2026-08-19 (4 disks; the MX300 was pulled):
#   2x ADATA SU800 953GB   -> RAID1 "md0-root" (LUKS+LVM / + /home + /mnt/vms)
#                             and RAID1 "md0-boot" (/boot)
#   2x Crucial 250GB       -> RAID1 "backup" -> LUKS -> /mnt/backup
# Drive letters AND md numbers shuffle across reboots, so nothing here may
# hardcode sdX/mdN -- the collector enumerates /sys/block and smartd uses
# DEVICESCAN. Hardcoding is what left sdd unmonitored until 2026-08-22.
#
# Run as root. Pass Telegram creds via env on first install (kept out of the
# tracked script; written to a root-only file):
#   cd /tmp && sudo TG_TOKEN=... TG_CHAT=... bash install-ssd-monitoring-15.sh
# Re-running without env reuses the existing /etc/default/smartd-telegram.
#
# Expects ssd-smart-loki-push.sh, smartd-telegram.sh, md-telegram.sh alongside.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo)"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

command -v smartctl >/dev/null || { echo "ERROR: smartmontools not installed (apt-get install smartmontools)"; exit 1; }
command -v mdadm    >/dev/null || { echo "ERROR: mdadm not installed (apt-get install mdadm)"; exit 1; }

echo "==> collector + notifiers"
install -m 0755 "$SRC/ssd-smart-loki-push.sh" /usr/local/bin/ssd-smart-loki-push.sh
install -m 0755 "$SRC/smartd-telegram.sh"     /usr/local/bin/smartd-telegram.sh
install -m 0755 "$SRC/md-telegram.sh"         /usr/local/bin/md-telegram.sh

echo "==> telegram secrets"
if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ]; then
  ( umask 077; printf 'TG_TOKEN=%s\nTG_CHAT=%s\n' "$TG_TOKEN" "$TG_CHAT" > /etc/default/smartd-telegram )
  chmod 600 /etc/default/smartd-telegram
  echo "    wrote /etc/default/smartd-telegram (0600)"
elif [ -r /etc/default/smartd-telegram ]; then
  echo "    reusing existing /etc/default/smartd-telegram"
else
  echo "ERROR: TG_TOKEN/TG_CHAT not set and /etc/default/smartd-telegram missing"; exit 1
fi

echo "==> systemd timer (collector every 10 min)"
cat > /etc/systemd/system/ssd-smart-loki.service <<'EOF'
[Unit]
Description=Push SSD SMART + RAID metrics to Loki (.20)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ssd-smart-loki-push.sh
EOF
cat > /etc/systemd/system/ssd-smart-loki.timer <<'EOF'
[Unit]
Description=Run SSD SMART->Loki collector every 10 min
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF

echo "==> smartd.conf"
# !! smartd reads /etc/smartd.conf -- NOT /etc/smartmontools/smartd.conf !!
# This script wrote the latter from 2026-07-03 to 2026-08-22, so every directive
# below (weekly self-test, temp thresholds, and the Telegram hook) was INERT for
# seven weeks. Coverage was never lost -- Ubuntu's stock /etc/smartd.conf carries a
# plain DEVICESCAN -- but its `-M exec` pointed at smartd-runner -> run.d/10mail ->
# mail to root, and there is no MTA on this host, so alerts went nowhere.
# smartd-telegram.sh had never once fired. Verify after ANY change with:
#     journalctl -u smartmontools -b | grep 'Opened configuration file'
SMARTD_CONF=/etc/smartd.conf
cat > "$SMARTD_CONF" <<'EOF'
# SSD health — all SMART-capable disks on .15 (2x ADATA SU800 main RAID1,
# 2x Crucial 250GB backup RAID1, + Crucial MX300 cold tier as of 2026-08-22).
# Managed via install-ssd-monitoring-15.sh (soc-home ansible/roles/suricata/files).
#
# DEVICESCAN, not a hardcoded device list: this used to name /dev/sd{a,b,c}
# explicitly, and .15 drive letters shuffle whenever a disk is added or pulled.
# DEVICESCAN applies the directives below to every disk it finds, so a disk
# added or reshuffled later is covered automatically.
# NOTE: smartd ignores all other device lines when DEVICESCAN is present; keep
# it as the only device entry.
#
# Weekly SHORT self-test Sunday 12:00 (inside the 06:00-23:00 awake window; soc-sleep 23:00-06:00).
# Temp: 4C delta tracking, info at 60C, critical at 70C.
# Alerts via /usr/local/bin/smartd-telegram.sh (no MTA on this host; -m root is a placeholder).
DEVICESCAN -a -o on -S on -s S/../../7/12 -W 4,60,70 -m root -M exec /usr/local/bin/smartd-telegram.sh
EOF
# Keep the legacy path identical so the two can never silently disagree again.
cp -a "$SMARTD_CONF" /etc/smartmontools/smartd.conf
if [ -f /etc/default/smartmontools ]; then
  sed -i 's/^#*start_smartd=.*/start_smartd=yes/' /etc/default/smartmontools || true
  grep -q '^start_smartd=' /etc/default/smartmontools || echo 'start_smartd=yes' >> /etc/default/smartmontools
fi

echo "==> mdadm monitor -> Telegram (PROGRAM hook)"
# mdadm --monitor (mdmonitor.service) runs PROGRAM on array events. No MTA here,
# so route through the Telegram hook. MAILADDR must exist for --monitor to arm.
if [ -f /etc/mdadm/mdadm.conf ]; then
  sed -i '/^PROGRAM /d' /etc/mdadm/mdadm.conf
  echo 'PROGRAM /usr/local/bin/md-telegram.sh' >> /etc/mdadm/mdadm.conf
  grep -q '^MAILADDR ' /etc/mdadm/mdadm.conf || echo 'MAILADDR root' >> /etc/mdadm/mdadm.conf
else
  echo "    WARN: /etc/mdadm/mdadm.conf missing — skipping PROGRAM hook"
fi

echo "==> enable"
systemctl daemon-reload
systemctl enable --now ssd-smart-loki.timer
systemctl restart smartmontools.service 2>/dev/null || systemctl restart smartd.service
systemctl restart mdmonitor.service 2>/dev/null || systemctl restart mdadm.service 2>/dev/null || true

echo "==> verify"
echo "-- collector test --"; /usr/local/bin/ssd-smart-loki-push.sh && echo "collector ran (pushed to Loki)"
echo "-- smartd.conf check --"; smartd -q onecheck -c "$SMARTD_CONF" >/dev/null 2>&1 && echo "smartd.conf OK" || echo "smartd.conf check returned nonzero (review)"
# Prove smartd loaded OUR file and not the distro default -- the exact failure that
# hid for seven weeks. Parsing OK is NOT sufficient evidence.
echo "-- which config did smartd actually open? --"
journalctl -u smartmontools --since "1 min ago" --no-pager 2>/dev/null | grep -m1 'Opened configuration file' \
  || echo "WARN: could not confirm from journal -- check manually"
echo "-- telegram test (smartd) --"; SMARTD_DEVICESTRING="/dev/sdb" SMARTD_MESSAGE="install test — SSD monitoring active on .15" SMARTD_FAILTYPE="TEST" /usr/local/bin/smartd-telegram.sh && echo "telegram test sent"
echo "-- telegram test (mdadm) --"; /usr/local/bin/md-telegram.sh TestMessage "$(readlink -f /dev/md/md0-root 2>/dev/null || echo /dev/md127)" && echo "mdadm telegram test sent"
echo "-- service status --"
echo "ssd-smart-loki.timer: $(systemctl is-active ssd-smart-loki.timer)"
echo "smartd: $(systemctl is-active smartmontools.service 2>/dev/null || systemctl is-active smartd.service)"
echo "mdmonitor: $(systemctl is-active mdmonitor.service 2>/dev/null || echo n/a)"
echo "DONE"
