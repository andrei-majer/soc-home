#!/bin/bash
# vboxautostart-warmup.sh — ExecStartPre for vboxautostart-service.service.
#
# Why: VBoxAutostart races its own VBoxSVC at cold boot. It is normally the first VBox client
# after boot, so it spawns VBoxSVC itself and then immediately calls IVirtualBox::machines.
# VBoxSVC answers E_ACCESSDENIED until it has finished initialising, and VBoxAutostart treats
# that as fatal:
#     Enumerating virtual machines failed with E_ACCESSDENIED
# It then starts NOTHING and still exits 0, so the failure is completely silent — the first
# symptom is a SOC with no SIEM and no canary.
#
# Seen on the 2026-08-23 08:13 and 09:28 boots of .15: VBoxSVC's log opened at 09:28:59.150 and
# VBoxAutostart gave up at 09:28:59.270, 120 ms later, while VBoxSVC was still loading
# VirtualBox.xml. The identical invocation run by hand against a warm VBoxSVC succeeds — which
# is what makes this a race rather than a config fault.
#
# Two waits, in order:
#   1. /dev/vboxdrv — the udev race already documented for soc-wake.sh, which loads vboxdrv
#      asynchronously well after the unit is eligible to start.
#   2. A successful `VBoxManage list vms` as andrei. That both warms VBoxSVC and proves it is
#      past initialisation, so the ExecStart that follows connects to a ready service.
set -u

VBOX=/usr/bin/VBoxManage
VM_USER=andrei

for _ in $(seq 1 60); do
  [ -c /dev/vboxdrv ] && break
  sleep 1
done

if [ ! -c /dev/vboxdrv ]; then
  echo "WARN: /dev/vboxdrv still absent after 60s — letting vboxautostart try anyway"
  exit 0
fi

for i in $(seq 1 30); do
  if runuser -u "$VM_USER" -- "$VBOX" list vms >/dev/null 2>&1; then
    echo "VBoxSVC warm after ${i}s"
    exit 0
  fi
  sleep 1
done

# Never fail the unit: a warm-up that did not manage to warm is still no worse than today's
# behaviour, and blocking the start would guarantee the outage this script exists to prevent.
echo "WARN: VBoxSVC did not become ready within 30s — letting vboxautostart try anyway"
exit 0
