#!/bin/bash
# soc-vm-boot.sh — start the SOC VM fleet on host boot. Run by soc-vm-boot.service.
#
# Replaces VirtualBox's own vboxautostart, which is FAIL-FAST: any single per-VM error
# aborts the entire run and it still exits 0, so the failure is silent. That bit us twice
# on 2026-08-23, for two unrelated reasons:
#
#   1. Enumeration — two VMs archived on the late-unlocking /mnt/cold LUKS volume were
#      cached inaccessible by VBoxSVC, so enumerating ALL machines died with
#      E_ACCESSDENIED before anything started. (Fixed separately: mount ordering, and
#      those VMs are now unregistered.)
#   2. Launch — suricata-vm-start.service started Suricata in the same second, so
#      VBoxAutostart got "already locked by a session" on the FIRST VM in its list and
#      abandoned OpenCanary and ELK, which were both down and both flagged. Proven by
#      hand: with Suricata running and the other two stopped, VBoxAutostart started
#      neither.
#
# The whole point of this script is that each VM is independent — one failing never stops
# the rest — and every outcome is logged to the journal instead of vanishing.
#
# Schedule matches soc-sleep/soc-wake: Suricata runs 24/7; ELK, T-Pot Hive and OpenCanary
# are only brought up inside the day window, so a night-time boot does not start VMs that
# soc-sleep would immediately shut down again. This is also what fixes "a mid-day reboot
# leaves T-Pot Hive down" — vboxautostart never started it (flag off) and soc-wake had
# already run for the day, so nothing did.
set -u

VBOX=/usr/bin/VBoxManage

ALWAYS_VMS=("Suricata")
DAY_VMS=("OpenCanary" "ELK" "T-Pot Hive")

log() { echo "[$(date +%T)] $*"; }

state_of() {
  "$VBOX" showvminfo "$1" --machinereadable 2>/dev/null \
    | awk -F= '/^VMState=/{print $2}' | tr -d '"'
}

start_vm() {
  local vm="$1" s
  s=$(state_of "$vm")
  case "$s" in
    running)
      log "skip $vm (already running)"
      return 0
      ;;
    "")
      log "WARN $vm is not registered or not accessible — skipping"
      return 1
      ;;
  esac
  log "startvm $vm (was: $s)"
  if "$VBOX" startvm "$vm" --type headless; then
    log "started $vm"
  else
    # Deliberately non-fatal: the next VM must still get its chance.
    log "ERROR failed to start $vm — continuing with the rest"
    return 1
  fi
}

# vboxdrv loads asynchronously via udev, after this unit is eligible to start.
for _ in $(seq 1 60); do
  [ -c /dev/vboxdrv ] && break
  sleep 1
done
if [ ! -c /dev/vboxdrv ]; then
  log "FATAL /dev/vboxdrv never appeared after 60s"
  exit 1
fi

for vm in "${ALWAYS_VMS[@]}"; do
  start_vm "$vm" || true
done

hour=$(date +%-H)
if [ "$hour" -ge 6 ] && [ "$hour" -lt 23 ]; then
  for vm in "${DAY_VMS[@]}"; do
    start_vm "$vm" || true
  done
else
  log "outside 06:00-23:00 — leaving ${DAY_VMS[*]} down (soc-wake starts them at 06:00)"
fi

log "boot start-up complete"
exit 0
