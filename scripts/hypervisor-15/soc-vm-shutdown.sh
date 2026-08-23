#!/bin/bash
# soc-vm-shutdown.sh — ACPI-shutdown EVERY running VirtualBox VM, then force-poweroff
# stragglers. Run as the ExecStop of soc-vm-shutdown.service, which systemd orders
# before vboxdrv.service on host reboot/poweroff.
#
# Why: a plain `reboot` of .15 kills the VBoxHeadless processes outright, so the guests
# land in VBox state `aborted` — the equivalent of yanking their power. Confirmed
# 2026-08-23, when an operator reboot left soc-sleep logging
#     skip ELK / T-Pot Hive / OpenCanary (state=aborted)
# ELK's Elasticsearch and T-Pot's 24 containers both recovered that time, but an unclean
# stop on every single reboot is an index-corruption path we shouldn't keep rolling.
#
# Why not VirtualBox's own hook: SHUTDOWN_USERS + SHUTDOWN=acpibutton in
# /etc/default/virtualbox does the same thing, but stop_vms() in vboxdrv.sh then waits a
# hardcoded 30s before unloading the module. ELK and T-Pot Hive need far longer than that,
# so they'd still be killed mid-shutdown — the failure would just move later.
#
# Covers ALL running VMs, not only the autostart-flagged ones: T-Pot Hive is started by
# soc-wake rather than vboxautostart, and needs a clean stop just as much.
set -u

TIMEOUT=${SOC_VM_SHUTDOWN_TIMEOUT:-180}
VBOX=/usr/bin/VBoxManage

running_vms() {
  "$VBOX" list runningvms 2>/dev/null | sed -e 's/^"\(.*\)" {.*}$/\1/'
}

mapfile -t VMS < <(running_vms)

if [ "${#VMS[@]}" -eq 0 ]; then
  echo "[$(date +%T)] no running VMs — nothing to do"
  exit 0
fi

for vm in "${VMS[@]}"; do
  echo "[$(date +%T)] ACPI shutdown: $vm"
  "$VBOX" controlvm "$vm" acpipowerbutton || echo "WARN: ACPI failed for $vm"
done

end=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$end" ]; do
  left=$(running_vms | grep -c . || true)
  if [ "$left" -eq 0 ]; then
    echo "[$(date +%T)] all VMs down cleanly"
    exit 0
  fi
  sleep 5
done

while read -r vm; do
  [ -z "$vm" ] && continue
  echo "[$(date +%T)] FORCE poweroff: $vm (still running after ${TIMEOUT}s)"
  "$VBOX" controlvm "$vm" poweroff || true
done < <(running_vms)
