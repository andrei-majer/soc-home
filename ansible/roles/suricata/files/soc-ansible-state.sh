#!/bin/bash
# ============================================================================
# SOC Ansible state collector wrapper
# - Default: runs state-collect.yml, appends host state JSON lines to log
# - --drift: additionally runs site.yml --check, parses PLAY RECAP, appends
#            drift JSON per host
# ============================================================================
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

REPO=/opt/soc-ansible
LOG=/var/log/soc-ansible/state.jsonl
PLAYBOOK="$REPO/playbooks/ops/state-collect.yml"
SITE="$REPO/playbooks/site.yml"
INV="$REPO/inventory/hosts.yml"
DRIFT_TMP=$(mktemp /tmp/soc-drift.XXXXXX)
trap 'rm -f "$DRIFT_TMP"' EXIT

mkdir -p /var/log/soc-ansible
touch "$LOG"

cd "$REPO" || { logger -t soc-ansible-state "FATAL: cannot cd $REPO"; exit 1; }

# Serialize collect+drift: concurrent runs share the default SSH ControlPath -> mux collisions, spurious unreachable, 2.5h wedge (2026-05-21)
exec 9>/run/soc-ansible-state.lock || { logger -t soc-ansible-state "FATAL: cannot open lockfile"; exit 1; }
if ! flock -n 9; then
    logger -t soc-ansible-state "another run in progress; skipping this cycle"
    exit 0
fi
# Dedicated control-socket dir so ad-hoc/manual ansible runs never share mux sockets with this wrapper
export ANSIBLE_SSH_CONTROL_PATH_DIR=/run/soc-ansible-state-cp
mkdir -p "$ANSIBLE_SSH_CONTROL_PATH_DIR"

# ---- State collection ----
if ! ansible-playbook -i "$INV" "$PLAYBOOK" >/tmp/soc-state-run.log 2>&1; then
    logger -t soc-ansible-state "state-collect.yml failed; see /tmp/soc-state-run.log"
fi

# ---- Optional drift check ----
if [ "${1:-}" = "--drift" ]; then
    ansible-playbook -i "$INV" "$SITE" --check >"$DRIFT_TMP" 2>&1 || true
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    awk '/PLAY RECAP/{flag=1;next} flag && /ok=/{print}' "$DRIFT_TMP" | \
    while read -r line; do
        host=$(echo "$line" | awk '{print $1}')
        ok=$(echo "$line" | grep -oE 'ok=[0-9]+' | cut -d= -f2)
        changed=$(echo "$line" | grep -oE 'changed=[0-9]+' | cut -d= -f2)
        unreachable=$(echo "$line" | grep -oE 'unreachable=[0-9]+' | cut -d= -f2)
        failed=$(echo "$line" | grep -oE 'failed=[0-9]+' | cut -d= -f2)
        [ -z "$host" ] && continue
        printf '{"ts":"%s","type":"drift","host":"%s","ok":%s,"changed_tasks":%s,"unreachable":%s,"failed":%s}\n' \
            "$ts" "$host" "${ok:-0}" "${changed:-0}" "${unreachable:-0}" "${failed:-0}" >> "$LOG"
    done
fi

exit 0
