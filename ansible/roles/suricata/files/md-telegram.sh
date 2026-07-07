#!/bin/sh
# mdadm --monitor PROGRAM target: notify Telegram on RAID array events.
# mdadm invokes: md-telegram.sh <event> <md-device> [component-device]
# Events include Fail, FailSpare, DegradedArray, DeviceDisappeared,
# RebuildStarted/RebuildNN/RebuildFinished, SpareActive, SparesMissing, TestMessage.
#
# mdadm fires RebuildStarted for BOTH a real degraded-array recovery AND the
# routine monthly consistency check (scrub). They are only distinguishable via
# the array's sync_action, so for Rebuild* events we read
# /sys/block/<md>/md/sync_action and label accordingly:
#   check  -> routine read-only scrub (benign)      repair -> scrub + auto-repair
#   recover-> REAL rebuild, array was degraded (!)  resync -> post-unclean-shutdown
# Secrets sourced from /etc/default/smartd-telegram (shared with smartd-telegram.sh,
# root 0600, NOT tracked in the repo). Best-effort — never blocks mdadm.
[ -r /etc/default/smartd-telegram ] && . /etc/default/smartd-telegram
[ -z "${TG_TOKEN:-}" ] && exit 0
event="${1:-?}"; array="${2:-?}"; comp="${3:-}"

icon="⚠️"; label="RAID event"
case "$event" in
  Fail*|DegradedArray|DeviceDisappeared|SparesMissing) icon="🔴"; label="RAID FAULT" ;;
  SpareActive)                                         icon="✅"; label="RAID spare active" ;;
  TestMessage)                                         icon="🧪"; label="RAID monitor test" ;;
  Rebuild*)
    case "$event" in RebuildFinished) verb="finished" ;; *) verb="started" ;; esac
    md="${array##*/}"                                   # /dev/md126 -> md126
    action=$(cat "/sys/block/${md}/md/sync_action" 2>/dev/null)
    case "$action" in
      check)   icon="🧹"; label="RAID scrub (monthly data-check) ${verb} — routine, read-only" ;;
      repair)  icon="🧹"; label="RAID scrub+repair ${verb} — routine" ;;
      recover) icon="🔴"; label="RAID REBUILD ${verb} — array was DEGRADED, a disk is being resynced" ;;
      resync)  icon="⚠️"; label="RAID resync ${verb} (recovery after unclean shutdown)" ;;
      reshape) icon="⚠️"; label="RAID reshape ${verb}" ;;
      *)       # sync_action already idle (fast array, or the Finished event) — infer from event
               case "$event" in
                 RebuildFinished) icon="✅"; label="RAID sync finished" ;;
                 *)               icon="ℹ️"; label="RAID sync ${verb}" ;;
               esac ;;
    esac ;;
esac

text="${icon} ${label} — .15
event=${event}
array=${array}${comp:+
component=${comp}}"
curl -fsS -m 10 \
  --data-urlencode "chat_id=${TG_CHAT}" \
  --data-urlencode "text=${text}" \
  "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null 2>&1 || true
exit 0
