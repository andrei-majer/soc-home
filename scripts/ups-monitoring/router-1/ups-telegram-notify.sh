#!/bin/sh
# UPS mains-state Telegram notifier (router .1).
# Fires ONE message on mains->battery (OL->OB) and ONE on battery->mains (OB->OL).
# Cron: * * * * * /usr/local/bin/ups-telegram-notify.sh
# Robust to WAN-down during an outage: a failed send is queued and retried every run,
# so the "power lost" alert still arrives (with its original timestamp) once WAN returns.
set -u

UPS="ted@localhost"
CONF="/etc/ups-telegram.conf"
STATE="/tmp/ups-telegram.state"
QUEUE="/tmp/ups-telegram.queue"
LOG="/tmp/ups-telegram.log"

[ -r "$CONF" ] || { echo "$(date) ERR no conf $CONF" >> "$LOG"; exit 0; }
. "$CONF"   # BOT_TOKEN, CHAT_ID
API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

send_telegram() {   # <text> -> 0 if delivered
  curl -fsS -m 15 -o /dev/null \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=$1" "$API"
}

flush_queue() {     # retry backlog; keep only still-failing lines
  [ -s "$QUEUE" ] || return 0
  tmp="${QUEUE}.new"; : > "$tmp"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if send_telegram "$line"; then echo "$(date) flushed: $line" >> "$LOG"
    else echo "$line" >> "$tmp"; fi
  done < "$QUEUE"
  mv "$tmp" "$QUEUE"
}

emit() {            # <text> : send now, queue on failure
  if send_telegram "$1"; then echo "$(date) sent: $1" >> "$LOG"
  else echo "$1" >> "$QUEUE"; echo "$(date) queued: $1" >> "$LOG"; fi
}

raw="${UPS_STATUS_OVERRIDE:-$(upsc "$UPS" ups.status 2>/dev/null)}"
case "$raw" in
  *OB*) cur="ON_BATTERY" ;;
  *OL*) cur="ONLINE" ;;
  *)    echo "$(date) unreadable status '$raw'" >> "$LOG"; exit 0 ;;
esac

flush_queue   # drain any backlog first (covers WAN-returned-after-outage)

prev=""; [ -r "$STATE" ] && prev="$(cat "$STATE" 2>/dev/null)"
now="$(date '+%Y-%m-%d %H:%M:%S %Z')"
if [ -z "$prev" ]; then
  :   # first run / post-reboot: baseline only, no alert
elif [ "$prev" != "$cur" ]; then
  if [ "$cur" = "ON_BATTERY" ]; then
    emit "🔴 POWER LOST — mains failed, running on UPS battery (router .1) @ ${now}"
  else
    emit "🟢 POWER RESTORED — mains back (router .1) @ ${now}"
  fi
fi
echo "$cur" > "$STATE"
