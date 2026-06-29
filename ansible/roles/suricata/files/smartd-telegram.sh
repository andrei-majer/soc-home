#!/bin/sh
# smartd -M exec target: notify Telegram on SMART warnings, self-test failures,
# and temperature thresholds. smartd sets SMARTD_* env and pipes a mail body on
# stdin (ignored). Secrets sourced from /etc/default/smartd-telegram (root 0600,
# NOT tracked in the repo). Best-effort — never blocks smartd.
[ -r /etc/default/smartd-telegram ] && . /etc/default/smartd-telegram
[ -z "${TG_TOKEN:-}" ] && exit 0
dev="${SMARTD_DEVICESTRING:-${SMARTD_DEVICE:-?}}"
msg="${SMARTD_MESSAGE:-SMART event}"
text="⚠️ SSD SMART alert — .15 ${dev}
${msg}
type=${SMARTD_FAILTYPE:-?}"
curl -fsS -m 10 \
  --data-urlencode "chat_id=${TG_CHAT}" \
  --data-urlencode "text=${text}" \
  "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null 2>&1 || true
exit 0
