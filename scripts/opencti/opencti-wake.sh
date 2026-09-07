#!/usr/bin/env bash
# opencti-wake.sh — resume the OpenCTI VM from savestate (or cold-boot).
#
# Canonical location: /usr/local/sbin/opencti-wake.sh on .20 (Suricata host).
# The .13 opencti-wake.ps1 is now a thin wrapper that SSHes here.
#
# Total wake time: ~45s from savestate (17s VBox resume + ~30s for ES/RabbitMQ
# to settle), ~90s from a cold boot (ES healthy ~60s, platform answers ~80s).
# Containers self-heal on savestate resume (preserved working state).
#
# Both waits retry on a back-off until a deadline (SSH 120s; stack 120s from
# savestate, 240s cold) because every check here races the boot.
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
#   1 = stack still not healthy when the retry deadline ran out
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

# How long to keep retrying. A cold boot needs far longer than a savestate
# resume: ES goes starting->healthy around 60s and the platform first answers
# around 80s, so anything shorter just reports a false failure.
SSH_DEADLINE=120
if [ "$was_cold_boot" -eq 1 ]; then STACK_DEADLINE=240; else STACK_DEADLINE=120; fi

# Wait for SSH on .22. Probe with a real authenticated command, NOT a bare
# /dev/tcp connect: port 22 accepts connections during early boot before sshd
# can actually serve, so the old TCP probe declared "ready" ~60s too early and
# the very next SSH call failed outright (2026-09-07 cold boot, exit 2).
echo "Waiting for SSH on $OCTI_HOST..."
t0=$(date +%s)
ssh_ready=0
delay=3
while [ $(( $(date +%s) - t0 )) -lt "$SSH_DEADLINE" ]; do
    if octi_ssh true >/dev/null 2>&1; then
        ssh_ready=1; break
    fi
    sleep "$delay"
    [ "$delay" -lt 10 ] && delay=$(( delay + 2 ))
done
elapsed=$(( $(date +%s) - t0 ))
if [ "$ssh_ready" -ne 1 ]; then
    echo "${RED}ERROR: SSH not usable after ${elapsed}s${RST}"
    exit 2
fi
echo "SSH ready after ${elapsed}s"

# Verify containers + platform. Everything here is a boot race, so probe on a
# back-off until healthy or the deadline — a single shot only ever caught the
# stack mid-start. `?` means that probe itself could not run (SSH refused).
container_count='?'; svc_state='?'; http_code='000'

probe_stack() {
    local check
    check=$(octi_ssh 'docker ps -q | wc -l; systemctl is-active opencti' 2>/dev/null) || {
        container_count='?'; svc_state='ssh-failed'; http_code='000'
        return 1
    }
    container_count=$(printf '%s\n' "$check" | sed -n '1p' | tr -d ' ')
    svc_state=$(printf '%s\n' "$check" | sed -n '2p' | tr -d ' ')
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://$OCTI_HOST:8080/health" 2>/dev/null || echo 000)

    # 11 since worker replicas cut 3->1 (2026-06-12); was 13
    [ "$container_count" != '?' ] && [ "$container_count" -ge 11 ] 2>/dev/null \
        && [ "$svc_state" = active ] \
        && { [ "$http_code" = 401 ] || [ "$http_code" = 200 ]; }
}

echo "Checking OpenCTI stack (up to ${STACK_DEADLINE}s)..."
t0=$(date +%s)
stack_healthy=0
delay=5
while :; do
    if probe_stack; then stack_healthy=1; break; fi
    elapsed=$(( $(date +%s) - t0 ))
    [ "$elapsed" -ge "$STACK_DEADLINE" ] && break
    echo "  not ready yet (${elapsed}s): containers=$container_count opencti=$svc_state http=$http_code"
    sleep "$delay"
    [ "$delay" -lt 20 ] && delay=$(( delay + 5 ))
done

echo "Containers running: $container_count"
echo "opencti systemd:    $svc_state"
echo "platform HTTP:      $http_code (401 = auth required = healthy)"

if [ "$stack_healthy" -ne 1 ]; then
    echo "${YEL}WARN: stack still not healthy after $(( $(date +%s) - t0 ))s${RST}"
    exit 1
fi
echo "Stack healthy after $(( $(date +%s) - t0 ))s"

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
