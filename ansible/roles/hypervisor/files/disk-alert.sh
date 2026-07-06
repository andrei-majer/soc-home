#!/bin/sh
# Telegram alert when / or /mnt/vms crosses THRESH% used. One alert per crossing
# (flag files in /run). Reuses smartd/mdadm Telegram creds. Best-effort.
[ -r /etc/default/smartd-telegram ] && . /etc/default/smartd-telegram
[ -z "${TG_TOKEN:-}" ] && exit 0
THRESH=85
FLAGDIR=/run/disk-alert
mkdir -p "$FLAGDIR"
send() {
  curl -fsS -m 10 \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=$1" \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null 2>&1 || true
}
for m in / /mnt/vms; do
  use=$(df --output=pcent "$m" 2>/dev/null | tail -1 | tr -dc '0-9')
  [ -z "$use" ] && continue
  flag="$FLAGDIR/$(echo "$m" | tr '/' '_').over"
  if [ "$use" -ge "$THRESH" ]; then
    if [ ! -f "$flag" ]; then
      send "🔴 disk .15 — ${m} at ${use}% (>=${THRESH}%). Prune docker or free space."
      touch "$flag"
    fi
  else
    [ -f "$flag" ] && send "✅ disk .15 — ${m} back under ${THRESH}% (${use}%)."
    rm -f "$flag"
  fi
done
