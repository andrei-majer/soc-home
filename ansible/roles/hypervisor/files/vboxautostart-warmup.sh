#!/bin/bash
# vboxautostart-warmup.sh — ExecStartPre for vboxautostart-service.service.
#
# THE ACTUAL BUG (diagnosed 2026-08-23, after a first wrong theory — see below):
#
# VBoxSVC caches each machine's accessibility ONCE, when it starts. Two archived VMs,
# OpenClaw and T-Pot Sensor, live on /mnt/cold — a LUKS volume that unlocks late in boot.
# If VBoxSVC comes up before that mount, those two machines are inaccessible to it and
# STAY inaccessible for the life of that VBoxSVC.
#
# VBoxAutostart enumerates ALL registered machines. It hits the inaccessible pair, the
# property read fails with E_ACCESSDENIED (component MachineWrap, interface IMachine), and
# it aborts the entire run:
#     Enumerating virtual machines failed with E_ACCESSDENIED
# It then starts NOTHING and still exits 0 — so systemd reports success and the first
# symptom is a SOC with no SIEM and no canary. Two reboots in a row came back that way.
#
# Measured on the 10:10 boot:
#     10:10:01  Starting systemd-cryptsetup@cryptcold
#     10:10:06  VBoxSVC spawned
#     10:10:06  Starting vboxautostart-service
#     10:10:08  Mounted /mnt/cold        <-- two seconds too late
#
# The real fix is RequiresMountsFor=/mnt/vms /mnt/cold in the drop-in (and on every other
# unit that can spawn VBoxSVC — suricata-vm-start, soc-wake, soc-vm-shutdown). This script
# is belt-and-braces for the case where a mount unit reports done before the path is
# actually usable, and it must NOT spawn VBoxSVC until the stores are really there.
#
# FIRST THEORY, WRONG, KEPT SO NOBODY RE-TREADS IT: that VBoxAutostart was racing its own
# VBoxSVC spawn. It looked convincing — the failure was 120ms after VBoxSVC's log opened,
# and re-running the same command by hand against a warm VBoxSVC succeeded. But warming
# VBoxSVC did not fix the next boot, and the decisive evidence was that only ONE VBoxSVC
# existed that boot: it had already served the warm-up's `list vms` successfully and then
# denied VBoxAutostart 10ms later. Same process, one client fine, the other refused — so
# readiness was never the issue. Worse, warming early actively HURT: it pinned the
# inaccessible state in cache two seconds before /mnt/cold mounted.
set -u

VBOX=/usr/bin/VBoxManage
VM_USER=andrei
STORES=(/mnt/vms /mnt/cold)

# 1. Both VM stores must be mounted before anything touches VBox.
for store in "${STORES[@]}"; do
  for _ in $(seq 1 60); do
    mountpoint -q "$store" && break
    sleep 1
  done
  if ! mountpoint -q "$store"; then
    echo "WARN: $store not mounted after 60s — VMs stored there will be inaccessible"
  fi
done

# 2. vboxdrv loads asynchronously via udev, well after this unit is eligible to start.
for _ in $(seq 1 60); do
  [ -c /dev/vboxdrv ] && break
  sleep 1
done

if [ ! -c /dev/vboxdrv ]; then
  echo "WARN: /dev/vboxdrv still absent after 60s — letting vboxautostart try anyway"
  exit 0
fi

# 3. Only now warm VBoxSVC, so it caches the machines as accessible.
for i in $(seq 1 30); do
  if runuser -u "$VM_USER" -- "$VBOX" list vms >/dev/null 2>&1; then
    echo "VBoxSVC warm after ${i}s"
    exit 0
  fi
  sleep 1
done

# Never fail the unit: blocking the start would guarantee the outage this exists to prevent.
echo "WARN: VBoxSVC did not become ready within 30s — letting vboxautostart try anyway"
exit 0
