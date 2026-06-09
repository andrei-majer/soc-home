#!/bin/bash
# soc-wake.sh — cold-boot SOC VMs in the morning; verify each via ping with one auto-reset.
# Invoked by soc-wake.service (timer @ 06:00 daily). Logs via journal.
set -u
declare -A SOC_VMS=(
  ["Suricata"]="192.168.1.120"
  ["ELK"]="192.168.1.133"
  ["T-Pot Hive"]="192.168.1.130"
  ["OpenCanary"]="192.168.1.140"
)
PING_RETRIES=12
PING_INTERVAL=15
VBOX=/usr/bin/VBoxManage

# Wait for vboxdrv to be available (boot race — module may load after the
# timer fires when Persistent=true catches up a missed schedule).
for i in $(seq 1 30); do
  [ -c /dev/vboxdrv ] && break
  echo "[$(date +%T)] waiting for /dev/vboxdrv (attempt $i)"
  sleep 2
done
if [ ! -c /dev/vboxdrv ]; then
  echo "FATAL: /dev/vboxdrv missing after 60s — aborting wake"
  exit 1
fi

state_of() {
  "$VBOX" showvminfo "$1" --machinereadable 2>/dev/null \
    | awk -F= '/^VMState=/{print $2}' \
    | tr -d '"'
}

for vm in "${!SOC_VMS[@]}"; do
  s=$(state_of "$vm")
  if [ "$s" = "running" ]; then
    echo "[$(date +%T)] skip $vm (already running)"
  else
    echo "[$(date +%T)] startvm: $vm"
    "$VBOX" startvm "$vm" --type headless || echo "WARN: startvm failed for $vm"
  fi
done

echo "[$(date +%T)] initial 60s wait for guest boot"
sleep 60

for vm in "${!SOC_VMS[@]}"; do
  ip="${SOC_VMS[$vm]}"
  echo "[$(date +%T)] verify $vm at $ip"
  ok=0
  for i in $(seq 1 $PING_RETRIES); do
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
      echo "[$(date +%T)] $vm OK (attempt $i)"
      ok=1
      break
    fi
    if [ $i -eq 6 ]; then
      echo "[$(date +%T)] $vm unreachable after $((i*PING_INTERVAL))s — resetting"
      "$VBOX" controlvm "$vm" reset 2>/dev/null || true
    fi
    sleep $PING_INTERVAL
  done
  [ $ok -eq 0 ] && echo "WARN: $vm still unreachable at end of wake"
done
echo "[$(date +%T)] wake done"
