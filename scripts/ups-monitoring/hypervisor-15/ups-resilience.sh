#!/usr/bin/env bash
# Resilient UPS power-loss handler. Installed at /usr/local/bin/ups-resilience.sh.
# Triggered on ONBATT (via upssched -> ups-resilience.service). DRY-RUN unless
# /etc/nut/ARMED exists: logs decisions but never suspends or shuts down.
set -uo pipefail
ARMED=/etc/nut/ARMED
UPS=ted
INTERVAL=180        # seconds asleep between power re-checks
DEBOUNCE=15         # initial grace to ride out brief flickers

log(){ logger -t ups-resilience "$*"; }
st(){ upsc "$UPS" ups.status 2>/dev/null; }
vb(){ upsc "$UPS" battery.voltage 2>/dev/null; }
armed(){ [ -e "$ARMED" ]; }

exec 9>/run/ups-resilience.lock
flock -n 9 || { log "another instance running; exiting"; exit 0; }

log "triggered (armed=$(armed && echo YES || echo DRY-RUN)); debounce ${DEBOUNCE}s"
sleep "$DEBOUNCE"

while true; do
  s="$(st)"
  case " $s " in
    *" OL "*) log "mains present (status='$s') — staying up, exiting"; exit 0 ;;
  esac
  case " $s " in
    *" LB "*)
      log "LOW BATTERY (status='$s', vbatt=$(vb)) — clean shutdown"
      if armed; then
        timeout 180 systemctl start soc-sleep.service \
          || log "soc-sleep start failed/timed out; proceeding to poweroff anyway"
        systemctl poweroff
      else
        log "DRY-RUN: would soc-sleep + poweroff now"
      fi
      exit 0 ;;
  esac
  log "on battery (status='$s', vbatt=$(vb)) — suspending ${INTERVAL}s"
  if armed; then
    target=$(( $(date +%s) + INTERVAL ))
    /usr/sbin/rtcwake -m no -s "$INTERVAL" >/dev/null 2>&1 || log "rtcwake arm failed; busy-waiting"
    sync
    systemctl suspend
    # CLOCK_REALTIME jumps across the suspend, so this waits ~INTERVAL wall-time
    while [ "$(date +%s)" -lt "$target" ]; do sleep 5; done
    log "resumed — re-checking power"
  else
    log "DRY-RUN: would suspend ${INTERVAL}s; idling 15s instead"
    sleep 15
  fi
done
