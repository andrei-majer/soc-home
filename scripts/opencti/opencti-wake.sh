#!/usr/bin/env bash
# opencti-wake.sh — resume the OpenCTI VM from savestate (or cold-boot).
#
# Canonical location: /usr/local/sbin/opencti-wake.sh on .20 (Suricata host).
# The .13 opencti-wake.ps1 is now a thin wrapper that SSHes here.
#
# Total wake time: ~45s (17s VBox resume + ~30s for ES/RabbitMQ to settle).
# Containers self-heal on savestate resume (preserved working state).
#
# On a COLD boot from saved/poweroff (as opposed to savestate resume), the 5
# TI connectors + worker get stuck in a Python retry loop because ES isn't
# ready yet when they first try to reach the platform API — their Docker
# containers stay `running` but the process inside spins forever. This script
# restarts them AFTER the platform is verified healthy. See memory
# `opencti-135` "Connectors stuck in Python retry loop after cold-boot".
#
# Usage:
#   sudo /usr/local/sbin/opencti-wake.sh              # resume + verify
#   sudo /usr/local/sbin/opencti-wake.sh --no-verify  # resume, return immediately
#   sudo /usr/local/sbin/opencti-wake.sh --no-restart # skip cold-boot connector restart
#
# Exit codes:
#   0 = OK (VM running + stack healthy)
#   1 = stack not fully healthy yet (give 30-60s more)
#   2 = SSH / VBoxManage / unexpected state error

set -u
NO_VERIFY=0
NO_RESTART=0
for a in "$@"; do
    case "$a" in
        --no-verify) NO_VERIFY=1 ;;
        --no-restart) NO_RESTART=1 ;;
        *) echo "ERROR: unknown arg: $a" >&2; exit 2 ;;
    esac
done

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
HV_USER=andrei
HV_HOST=192.168.1.15
OCTI_HOST=192.168.1.22
VM_NAME=OpenCTi  # VirtualBox name (lowercase 'i' — see soc-lab/infrastructure.md)

RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; RST=$'\e[0m'

hv_ssh() { ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$HV_USER@$HV_HOST" "$@"; }
octi_ssh() { ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$OCTI_HOST" "$@"; }

get_vm_state() {
    local info
    info=$(hv_ssh "VBoxManage showvminfo $VM_NAME --machinereadable") || return 1
    printf '%s\n' "$info" | awk -F'"' '/^VMState=/{print $2; exit}'
}

state=$(get_vm_state) || { echo "${RED}ERROR: failed to query VM state on $HV_HOST${RST}"; exit 2; }
echo "OpenCTI VM current state: $state"

was_cold_boot=0
case "$state" in
    running)
        echo "${YEL}VM already running — nothing to wake.${RST}"
        [ "$NO_VERIFY" -eq 1 ] && exit 0
        ;;
    saved|poweroff)
        [ "$state" = poweroff ] && was_cold_boot=1
        echo "Resuming $VM_NAME ($state -> running)..."
        t0=$(date +%s)
        if ! hv_ssh "VBoxManage startvm $VM_NAME --type headless"; then
            echo "${RED}ERROR: startvm failed${RST}"
            exit 2
        fi
        echo "startvm took $(( $(date +%s) - t0 ))s"
        ;;
    *)
        echo "${RED}ERROR: unexpected state '$state' — refusing to startvm${RST}"
        exit 2
        ;;
esac

[ "$NO_VERIFY" -eq 1 ] && exit 0

# Wait for SSH on .22 (up to 90s)
echo "Waiting for SSH on $OCTI_HOST..."
t0=$(date +%s)
ssh_ready=0
for _ in $(seq 1 30); do
    if timeout 3 bash -c "</dev/tcp/$OCTI_HOST/22" 2>/dev/null; then
        ssh_ready=1; break
    fi
    sleep 3
done
elapsed=$(( $(date +%s) - t0 ))
if [ "$ssh_ready" -ne 1 ]; then
    echo "${RED}ERROR: SSH not reachable after ${elapsed}s${RST}"
    exit 2
fi
echo "SSH ready after ${elapsed}s"

# Verify containers + platform
echo "Checking OpenCTI stack..."
check=$(octi_ssh 'docker ps -q | wc -l; systemctl is-active opencti' 2>&1) || { echo "${RED}ERROR: SSH to $OCTI_HOST failed${RST}"; exit 2; }
container_count=$(printf '%s\n' "$check" | sed -n '1p' | tr -d ' ')
svc_state=$(printf '%s\n' "$check" | sed -n '2p' | tr -d ' ')

echo "Containers running: $container_count"
echo "opencti systemd:    $svc_state"

http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://$OCTI_HOST:8080/health" || echo 000)
echo "platform HTTP:      $http_code (401 = auth required = healthy)"

# 11 since worker replicas cut 3->1 (2026-06-12); was 13
if [ "$container_count" -ge 11 ] && [ "$svc_state" = active ] && { [ "$http_code" = 401 ] || [ "$http_code" = 200 ]; }; then
    stack_healthy=1
else
    stack_healthy=0
fi

if [ "$stack_healthy" -ne 1 ]; then
    echo "${YEL}WARN: stack not fully healthy yet — give it 30-60s more${RST}"
    exit 1
fi

# Post-boot connector restart. On cold-boot from poweroff, connectors race ES
# and stick in Python retry (see script header). Unconditional restart is
# cheaper than probing GraphQL — takes ~2s, harmless if they were already fine.
# Skipped on savestate resume (containers preserve working state).
if [ "$was_cold_boot" -eq 1 ] && [ "$NO_RESTART" -ne 1 ]; then
    echo "Cold-boot detected — restarting TI connectors + worker to clear any stuck retry-loop..."
    if octi_ssh 'docker restart opencti-connector-misp-1 opencti-connector-threatfox-1 opencti-connector-urlhaus-1 opencti-connector-mitre-1 opencti-connector-cisa-kev-1 opencti-worker-1' >/dev/null; then
        echo "${GRN}Connectors + worker restarted.${RST}"
    else
        echo "${YEL}WARN: connector restart returned non-zero${RST}"
    fi
fi

echo "${GRN}OK: OpenCTI is awake and ready. Sleep again with opencti-sleep.sh${RST}"
exit 0
