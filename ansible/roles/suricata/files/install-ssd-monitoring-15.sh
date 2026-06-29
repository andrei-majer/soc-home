#!/usr/bin/env bash
# Install SSD SMART monitoring on the .15 hypervisor:
#   - Loki collector (systemd timer, every 10 min) -> Grafana on .120
#   - smartd weekly SHORT self-test + temperature watch -> Telegram alerts
#
# Run as root. Pass Telegram creds via env on first install (kept out of the
# tracked script; written to a root-only file):
#   cd /tmp && sudo TG_TOKEN=... TG_CHAT=... bash install-ssd-monitoring-15.sh
# Re-running without env reuses the existing /etc/default/smartd-telegram.
#
# Expects ssd-smart-loki-push.sh and smartd-telegram.sh alongside this script.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo)"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

command -v smartctl >/dev/null || { echo "ERROR: smartmontools not installed (apt-get install smartmontools)"; exit 1; }

echo "==> collector + notifier"
install -m 0755 "$SRC/ssd-smart-loki-push.sh" /usr/local/bin/ssd-smart-loki-push.sh
install -m 0755 "$SRC/smartd-telegram.sh"     /usr/local/bin/smartd-telegram.sh

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
Description=Push SSD SMART metrics to Loki (.120)
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
cat > /etc/smartmontools/smartd.conf <<'EOF'
# SSD health — Crucial MX300 (sda) + MX500 (sdb). Managed via install-ssd-monitoring-15.sh.
# Weekly SHORT self-test Sunday 12:00 (inside the 06:00-23:00 awake window; soc-sleep 23:00-06:00).
# Temp: 4C delta tracking, info at 60C, critical at 70C (sda historically peaked 78C).
# Alerts via /usr/local/bin/smartd-telegram.sh (no MTA on this host; -m root is a placeholder).
/dev/sda -a -o on -S on -s S/../../7/12 -W 4,60,70 -m root -M exec /usr/local/bin/smartd-telegram.sh
/dev/sdb -a -o on -S on -s S/../../7/12 -W 4,60,70 -m root -M exec /usr/local/bin/smartd-telegram.sh
EOF
if [ -f /etc/default/smartmontools ]; then
  sed -i 's/^#*start_smartd=.*/start_smartd=yes/' /etc/default/smartmontools || true
  grep -q '^start_smartd=' /etc/default/smartmontools || echo 'start_smartd=yes' >> /etc/default/smartmontools
fi

echo "==> enable"
systemctl daemon-reload
systemctl enable --now ssd-smart-loki.timer
systemctl restart smartmontools.service 2>/dev/null || systemctl restart smartd.service

echo "==> verify"
echo "-- collector test --"; /usr/local/bin/ssd-smart-loki-push.sh && echo "collector ran (pushed to Loki)"
echo "-- smartd.conf check --"; smartd -q onecheck -c /etc/smartmontools/smartd.conf >/dev/null 2>&1 && echo "smartd.conf OK" || echo "smartd.conf check returned nonzero (review)"
echo "-- telegram test --"; SMARTD_DEVICESTRING="/dev/sda" SMARTD_MESSAGE="install test — SSD monitoring active on .15" SMARTD_FAILTYPE="TEST" /usr/local/bin/smartd-telegram.sh && echo "telegram test sent"
echo "-- service status --"
echo "ssd-smart-loki.timer: $(systemctl is-active ssd-smart-loki.timer)"
echo "smartd: $(systemctl is-active smartmontools.service 2>/dev/null || systemctl is-active smartd.service)"
echo "DONE"
