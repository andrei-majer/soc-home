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
        # soc-vm-shutdown, NOT soc-sleep. Two reasons, both discovered 2026-08-23:
        #  1. soc-sleep.sh gained a window guard and no-ops outside 23:00-06:00, so on a
        #     DAYTIME outage this call would silently do nothing at all.
        #  2. soc-sleep only ever covered ELK / T-Pot Hive / OpenCanary — never Suricata.
        # Stopping soc-vm-shutdown.service runs its ExecStop, which ACPI-stops EVERY
        # running VM regardless of the time of day. (systemctl poweroff below would also
        # trigger it, but doing it explicitly keeps the timeout and the logging here.)
        timeout 200 systemctl stop soc-vm-shutdown.service \
          || log "soc-vm-shutdown failed/timed out; proceeding to poweroff anyway"
        systemctl poweroff
      else
        log "DRY-RUN: would soc-vm-shutdown + poweroff now"
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
