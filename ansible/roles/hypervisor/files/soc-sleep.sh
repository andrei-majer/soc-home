#!/bin/bash
# soc-sleep.sh — ACPI shutdown of SOC VMs nightly; force-poweroff stragglers after 5 min.
# Invoked by soc-sleep.service (timer @ 23:00 daily). Logs via journal.
# Suricata (.20) excluded 2026-07-16: hosts Grafana, kept up 24/7 for Tailscale mobile access.
set -u

# Both soc-sleep.timer and soc-wake.timer carry Persistent=true, so a host boot outside
# 23:00-06:00 replays BOTH missed schedules seconds apart. Seen 2026-08-23: after a
# daytime reboot, soc-sleep and soc-wake both fired at 08:12:59 — wake won only because
# it started one second later, and sleep no-op'd solely because the VMs happened to be in
# state `aborted`. On a clean boot, sleep would ACPI-down exactly what wake just started.
# Pass --force for an ad-hoc run (e.g. before a planned host reboot).
if [ "${1:-}" != "--force" ]; then
  hour=$(date +%-H)
  if [ "$hour" -lt 23 ] && [ "$hour" -ge 6 ]; then
    echo "[$(date +%T)] outside the 23:00-06:00 sleep window (hour=$hour) — no-op. Use --force to override."
    exit 0
  fi
fi

SOC_VMS=("ELK" "T-Pot Hive" "OpenCanary")
TIMEOUT=300
VBOX=/usr/bin/VBoxManage

state_of() {
  "$VBOX" showvminfo "$1" --machinereadable 2>/dev/null \
    | awk -F= '/^VMState=/{print $2}' \
    | tr -d '"'
}

for vm in "${SOC_VMS[@]}"; do
  s=$(state_of "$vm")
  if [ "$s" = "running" ]; then
    echo "[$(date +%T)] ACPI shutdown: $vm"
    "$VBOX" controlvm "$vm" acpipowerbutton || echo "WARN: ACPI failed for $vm"
  else
    echo "[$(date +%T)] skip $vm (state=$s)"
  fi
done

end=$(( $(date +%s) + TIMEOUT ))
while [ $(date +%s) -lt $end ]; do
  running=0
  for vm in "${SOC_VMS[@]}"; do
    [ "$(state_of "$vm")" = "running" ] && running=1 && break
  done
  [ $running -eq 0 ] && { echo "[$(date +%T)] all VMs down cleanly"; exit 0; }
  sleep 5
done

for vm in "${SOC_VMS[@]}"; do
  s=$(state_of "$vm")
  if [ "$s" = "running" ]; then
    echo "[$(date +%T)] FORCE poweroff: $vm (timeout)"
    "$VBOX" controlvm "$vm" poweroff || true
  fi
done
