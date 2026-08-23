#!/usr/bin/env bash
# soc-vm-watchdog.sh — watches the whole SOC VM fleet on .15, not just Suricata.
# Replaces suricata-watchdog.sh (which only ever checked one VM).
#
# Why it exists in this form: on 2026-08-23 two consecutive reboots of .15 came back with ELK
# and OpenCanary down — no SIEM ingest, no canary — and NOTHING said so. vboxautostart had
# raced its own VBoxSVC, started nothing, and exited 0. The old watchdog watched Suricata,
# which `suricata-vm-start.service` had brought up correctly, so it stayed silent throughout.
#
# Two checks per VM:
#   1. present  — the VM is in `VBoxManage list runningvms`. Alerts on the first miss: a VM
#                 that is not running is unambiguous.
#   2. reachable — a TCP probe of its key service port from .15 over the LAN. Needs 2
#                 consecutive misses before alerting, so a service restart does not page.
#                 This is what closes the old "VM up but the guest is dead" coverage gap,
#                 and it needs no SSH from .15 to the guests (which is not set up).
#
# Runs as `andrei` from crontab every 5 min. VBoxManage needs no sudo — andrei owns the VMs.
# Quiet no-op while healthy; re-alerts every RENOTIFY_SEC while still broken; sends a
# recovery message per VM. Alerts are batched into one Telegram message per run.

set -u

BASE_DIR="/home/andrei/soc-watchdog"
STATE_DIR="${BASE_DIR}/state"
LOG_FILE="${BASE_DIR}/watchdog.log"
TELEGRAM_ENV="/home/andrei/teslamate/.telegram.env"
VBOX="/usr/bin/VBoxManage"

RENOTIFY_SEC=$((3 * 3600))   # re-alert every 3h while still broken
PROBE_STRIKES=2              # consecutive port-probe misses before alerting
PROBE_TIMEOUT=4
BOOT_GRACE_SEC=$((10 * 60))  # stay quiet for 10 min after a host boot

# name|schedule|probe host:port
#   always = expected up 24/7
#   day    = follows the soc-sleep/soc-wake cycle (23:00 ACPI down, 06:00 cold boot),
#            so it is only expected during the day window below
# Suricata is excluded from SOC_VMS in soc-sleep.sh and stays up 24/7.
FLEET=(
  "Suricata|always|192.168.1.20:22"
  "ELK|day|192.168.1.21:9200"
  "T-Pot Hive|day|192.168.1.23:64297"
  "OpenCanary|day|192.168.1.24:80"
)

# Day window, deliberately inside 06:00-23:00 so the wake cold-boot and the sleep ACPI
# shutdown both have slack and never produce a spurious page.
DAY_START=$((6 * 60 + 15))    # 06:15
DAY_END=$((22 * 60 + 45))     # 22:45

mkdir -p "$STATE_DIR"

log() { echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"; }

send_telegram() {
  local msg="$1"
  [ -f "$TELEGRAM_ENV" ] || { log "no telegram env, would have sent: ${msg//$'\n'/ | }"; return 0; }
  # shellcheck disable=SC1090
  . "$TELEGRAM_ENV"
  curl -sS --max-time 10 \
    -d "chat_id=${TG_CHAT}" \
    --data-urlencode "text=${msg}" \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" > /dev/null \
    && log "alert sent: ${msg//$'\n'/ | }" \
    || log "telegram send FAILED: ${msg//$'\n'/ | }"
}

# printf, not echo: echo's trailing newline becomes a trailing '_' in the state filename.
slug() { printf '%s' "$1" | tr -c '[:alnum:]' '_'; }

in_day_window() {
  local mins=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  [ "$mins" -ge "$DAY_START" ] && [ "$mins" -le "$DAY_END" ]
}

host_just_booted() {
  local up
  up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 999999)
  [ "$up" -lt "$BOOT_GRACE_SEC" ]
}

vm_running() { echo "$RUNNING_VMS" | grep -q "\"$1\""; }

port_open() {
  local hostport="$1"
  timeout "$PROBE_TIMEOUT" bash -c "</dev/tcp/${hostport%:*}/${hostport##*:}" 2>/dev/null
}

# --- main ---
if host_just_booted; then
  log "host up <${BOOT_GRACE_SEC}s — skipping while the fleet comes up"
  exit 0
fi

RUNNING_VMS=$("$VBOX" list runningvms 2>/dev/null)
if [ -z "$RUNNING_VMS" ] && ! "$VBOX" list vms >/dev/null 2>&1; then
  # VBoxManage itself is broken; reporting every VM as down would be misleading noise.
  log "VBoxManage not usable — skipping this run"
  exit 0
fi

now=$(date +%s)
problems=()
recoveries=()

for entry in "${FLEET[@]}"; do
  IFS='|' read -r vm schedule probe <<< "$entry"

  if [ "$schedule" = "day" ] && ! in_day_window; then
    continue
  fi

  key=$(slug "$vm")
  fails_file="${STATE_DIR}/${key}.fails"
  alert_file="${STATE_DIR}/${key}.alert"

  reason=""
  if ! vm_running "$vm"; then
    reason="VM not running"
    echo 99 > "$fails_file"            # unambiguous, alert on the first miss
  elif ! port_open "$probe"; then
    fails=$(cat "$fails_file" 2>/dev/null || echo 0)
    fails=$((fails + 1))
    echo "$fails" > "$fails_file"
    if [ "$fails" -ge "$PROBE_STRIKES" ]; then
      reason="VM up but ${probe} unreachable (${fails} consecutive checks)"
    else
      log "$vm: ${probe} probe failed (${fails}/${PROBE_STRIKES}) — not alerting yet"
    fi
  else
    # healthy
    rm -f "$fails_file"
    if [ -f "$alert_file" ]; then
      rm -f "$alert_file"
      recoveries+=("$vm")
    fi
    continue
  fi

  [ -n "$reason" ] || continue

  last_alert=0
  [ -f "$alert_file" ] && last_alert=$(cat "$alert_file" 2>/dev/null || echo 0)

  if [ $((now - last_alert)) -ge "$RENOTIFY_SEC" ]; then
    problems+=("${vm}: ${reason}")
    echo "$now" > "$alert_file"
  else
    log "$vm still broken (${reason}), next re-alert in $((RENOTIFY_SEC - (now - last_alert)))s"
  fi
done

if [ "${#problems[@]}" -gt 0 ]; then
  msg="⚠️ SOC watchdog on 9700k (.15):"
  for p in "${problems[@]}"; do msg="${msg}"$'\n'"• ${p}"; done
  msg="${msg}"$'\n'$'\n'"Start a VM with: VBoxManage startvm \"<name>\" --type headless"
  send_telegram "$msg"
fi

if [ "${#recoveries[@]}" -gt 0 ]; then
  msg="✅ SOC watchdog on 9700k (.15): recovered —"
  for r in "${recoveries[@]}"; do msg="${msg} ${r};"; done
  send_telegram "$msg"
fi

exit 0
