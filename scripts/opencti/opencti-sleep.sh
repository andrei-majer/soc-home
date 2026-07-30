#!/usr/bin/env bash
# opencti-sleep.sh — savestate the OpenCTI VM on .15.
#
# Canonical location: /usr/local/sbin/opencti-sleep.sh on .20 (Suricata host).
# The .13 opencti-sleep.ps1 is now a thin wrapper that SSHes here.
#
# Frees ~12 GB RAM on the hypervisor by writing the VM's RAM to disk. State is
# preserved exactly; resume via opencti-wake.sh (~45s to fully ready).
#
# Usage:
#   sudo /usr/local/sbin/opencti-sleep.sh
#
# Exit codes:
#   0 = savestate completed
#   1 = VM was not running (already saved or off)
#   2 = SSH / VBoxManage error

set -u
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
HV_USER=andrei
HV_HOST=192.168.1.15
VM_NAME=OpenCTi  # VirtualBox name (lowercase 'i' — see soc-lab/infrastructure.md)

RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; RST=$'\e[0m'

hv_ssh() { ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$HV_USER@$HV_HOST" "$@"; }

get_vm_state() {
    local info
    info=$(hv_ssh "VBoxManage showvminfo $VM_NAME --machinereadable") || return 1
    printf '%s\n' "$info" | awk -F'"' '/^VMState=/{print $2; exit}'
}

state=$(get_vm_state) || { echo "${RED}ERROR: failed to query VM state on $HV_HOST${RST}"; exit 2; }
echo "OpenCTI VM current state: $state"

if [ "$state" != running ]; then
    echo "${YEL}VM not running — nothing to save.${RST}"
    exit 1
fi

echo "Savestating $VM_NAME (writing ~12 GB RAM to disk; takes ~30-60s)..."
t0=$(date +%s)
if ! hv_ssh "VBoxManage controlvm $VM_NAME savestate"; then
    echo "${RED}ERROR: controlvm savestate failed${RST}"
    exit 2
fi
echo "Savestate took $(( $(date +%s) - t0 ))s"

state=$(get_vm_state) || { echo "${RED}ERROR: post-save state check failed${RST}"; exit 2; }
if [ "$state" = saved ]; then
    echo "${GRN}OK: OpenCTI VM is now in 'saved' state. Wake with opencti-wake.sh${RST}"
    exit 0
else
    echo "${RED}ERROR: post-savestate state is '$state' (expected 'saved')${RST}"
    exit 2
fi
