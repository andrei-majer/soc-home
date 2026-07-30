#!/usr/bin/env bash
# Suricata VM watchdog — checks the Suricata VBox VM is in runningvms.
# Alerts via Telegram (reuses ~/teslamate/.telegram.env creds).
# Re-alerts every RENOTIFY_SEC while still broken; quiet no-op when healthy.
# Runs as `andrei` from crontab; VBoxManage query needs no sudo (andrei owns the VMs).

set -u

VM_NAME="Suricata"
STATE_FILE="/home/andrei/suricata/watchdog.state"
LOG_FILE="/home/andrei/suricata/watchdog.log"
TELEGRAM_ENV="/home/andrei/teslamate/.telegram.env"
RENOTIFY_SEC=$((3 * 3600))   # re-alert every 3h while still broken

mkdir -p "$(dirname "$STATE_FILE")"

now_epoch() { date +%s; }
log() { echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"; }

send_telegram() {
  local msg="$1"
  [ -f "$TELEGRAM_ENV" ] || { log "no telegram env, would have sent: $msg"; return 0; }
  # shellcheck disable=SC1090
  . "$TELEGRAM_ENV"
  curl -sS --max-time 10 \
    -d "chat_id=${TG_CHAT}" \
    --data-urlencode "text=${msg}" \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" > /dev/null \
    && log "alert sent: $msg" \
    || log "telegram send FAILED: $msg"
}

is_vm_running() {
  VBoxManage list runningvms 2>/dev/null | grep -q "\"${VM_NAME}\""
}

# --- main ---
if is_vm_running; then
  # healthy — clear stale state if any, exit quiet
  if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    log "recovered: ${VM_NAME} VM back to running"
    send_telegram "✅ SOC watchdog: ${VM_NAME} VM back to running on 9700k (.15)"
  fi
  exit 0
fi

# VM not running — decide whether to alert
last_alert=0
[ -f "$STATE_FILE" ] && last_alert=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
now=$(now_epoch)

if [ $((now - last_alert)) -ge "$RENOTIFY_SEC" ]; then
  msg="⚠️ SOC watchdog: ${VM_NAME} VM is NOT running on 9700k (.15). Start with: VBoxManage startvm ${VM_NAME} --type headless"
  send_telegram "$msg"
  echo "$now" > "$STATE_FILE"
else
  log "still down, next re-alert in $((RENOTIFY_SEC - (now - last_alert)))s"
fi
