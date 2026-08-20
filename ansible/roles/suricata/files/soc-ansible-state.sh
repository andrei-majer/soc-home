#!/bin/bash
# ============================================================================
# SOC Ansible state collector wrapper
# - Default: runs state-collect.yml, appends host state JSON lines to log
# - --drift: additionally runs site.yml --check, parses PLAY RECAP, appends
#            drift JSON per host
# ============================================================================
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# 2026-08-20: the control node now runs from a FULL clone of the soc-home repo
# (/opt/soc-home), not the old standalone /opt/soc-ansible repo which had no git
# remote and drifted from GitHub. Ansible lives in its ansible/ subdirectory.
REPO=/opt/soc-home/ansible
LOG=/var/log/soc-ansible/state.jsonl
ALERT_STATE=/var/lib/soc-ansible/drift-alert.state
# Credentials come from the root-only (0600) relay conf so no secret lives in this
# script or in git. If it is missing we simply do not alert - never block collection.
TG_CONF=/etc/canary-relay.conf

notify() {  # $1 = message
    [ -r "$TG_CONF" ] || return 0
    # shellcheck disable=SC1090
    . "$TG_CONF"
    [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
    curl -s -m 10 -o /dev/null         --data-urlencode "chat_id=${TG_CHAT}"         --data-urlencode "text=$1"         "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" || true
}

# Edge-triggered: only notify when the signature CHANGES, so a persistent fault
# does not re-page every cycle, and recovery is announced once.
notify_edge() {  # $1 = key   $2 = signature ("" means healthy)   $3 = alert text   $4 = recovery text
    mkdir -p "$(dirname "$ALERT_STATE")"
    touch "$ALERT_STATE"
    prev=$(grep "^$1=" "$ALERT_STATE" 2>/dev/null | cut -d= -f2-)
    [ "$prev" = "$2" ] && return 0
    grep -v "^$1=" "$ALERT_STATE" > "$ALERT_STATE.tmp" 2>/dev/null || true
    printf '%s=%s
' "$1" "$2" >> "$ALERT_STATE.tmp"
    mv "$ALERT_STATE.tmp" "$ALERT_STATE"
    if [ -n "$2" ]; then notify "$3"; elif [ -n "$prev" ]; then notify "$4"; fi
}
PLAYBOOK="$REPO/playbooks/ops/state-collect.yml"
SITE="$REPO/playbooks/site.yml"
INV="$REPO/inventory/hosts.yml"
DRIFT_TMP=$(mktemp /tmp/soc-drift.XXXXXX)
trap 'rm -f "$DRIFT_TMP" "$DRIFT_TMP.failed"' EXIT

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
# Hard backstop: kill any single task exceeding 120s so an unattended cron run can never hang
export ANSIBLE_TASK_TIMEOUT=120

# ---- State collection ----
if ! ansible-playbook -i "$INV" "$PLAYBOOK" >/tmp/soc-state-run.log 2>&1; then
    logger -t soc-ansible-state "state-collect.yml failed; see /tmp/soc-state-run.log"
    # Before 2026-08-20 this was the ONLY signal and it went to syslog, so the
    # collector failed every 15 min for over a day with nobody noticing.
    notify_edge collect fail         "SOC IaC: state-collect.yml is FAILING on .20 - see /tmp/soc-state-run.log"         "SOC IaC: state-collect.yml recovered on .20"
else
    notify_edge collect "" "" "SOC IaC: state-collect.yml recovered on .20"
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
        # The loop runs in a pipeline subshell, so record failures in a FILE;
        # variable assignments here are invisible to the parent shell.
        [ "${failed:-0}" -gt 0 ] && printf '%s ' "$host" >> "$DRIFT_TMP.failed"
    done

    # A failed check task means the ROLE is broken for that host - the next real
    # converge would fail. Worth paging for. Drifted (changed) tasks are NOT: that is
    # the normal state of a lab. Unreachable is excluded too, because .22/.23/.25 are
    # on-demand VMs that are powered off by design most of the time.
    # The file only exists if at least one host failed. 2>/dev/null does NOT
    # suppress a redirection error (the shell fails before tr runs), so test first.
    if [ -f "$DRIFT_TMP.failed" ]; then
        failed_hosts=$(tr -s ' ' < "$DRIFT_TMP.failed" | sed 's/ $//')
    else
        failed_hosts=""
    fi
    rm -f "$DRIFT_TMP.failed"
    notify_edge drift "$failed_hosts" \
        "SOC IaC: site.yml --check FAILS for: ${failed_hosts} - that role is broken, a real converge would fail" \
        "SOC IaC: drift check passes for all hosts again"
fi

exit 0
