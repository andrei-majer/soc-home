#!/bin/sh
# mdadm --monitor PROGRAM target: notify Telegram on RAID array events.
# mdadm invokes: md-telegram.sh <event> <md-device> [component-device]
# Events include Fail, FailSpare, DegradedArray, DeviceDisappeared,
# RebuildStarted/Finished, SpareActive, SparesMissing, TestMessage.
# Secrets sourced from /etc/default/smartd-telegram (shared with smartd-telegram.sh,
# root 0600, NOT tracked in the repo). Best-effort — never blocks mdadm.
[ -r /etc/default/smartd-telegram ] && . /etc/default/smartd-telegram
[ -z "${TG_TOKEN:-}" ] && exit 0
event="${1:-?}"; array="${2:-?}"; comp="${3:-}"
icon="⚠️"
case "$event" in
  Fail*|DegradedArray|DeviceDisappeared|SparesMissing) icon="🔴" ;;
  RebuildFinished|SpareActive)                         icon="✅" ;;
  TestMessage)                                         icon="🧪" ;;
esac
text="${icon} RAID event — .15
event=${event}
array=${array}${comp:+
component=${comp}}"
curl -fsS -m 10 \
  --data-urlencode "chat_id=${TG_CHAT}" \
  --data-urlencode "text=${text}" \
  "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null 2>&1 || true
exit 0
