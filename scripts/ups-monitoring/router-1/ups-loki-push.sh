#!/bin/sh
# OpenWrt/BusyBox collector — install at /usr/bin/ups-loki-push.sh, run every minute
# via cron (see crontab.snippet). Pushes one logfmt line to Loki on .120 (host="1").
# Notes: BusyBox `date` lacks %N, so append zeros for ns; use `tr` (no bash ${//}).
LOKI="http://192.168.1.120:3100/loki/api/v1/push"
out="$(upsc ted 2>/dev/null)" || exit 0
g(){ echo "$out" | awk -F': ' -v k="$1" '$1==k{print $2; exit}'; }
bv="$(g battery.voltage)"; iv="$(g input.voltage)"; ov="$(g output.voltage)"
ld="$(g ups.load)"; tp="$(g ups.temperature)"; fr="$(g input.frequency)"
stat="$(g ups.status)"; statc="$(echo "$stat" | tr ' ' '_')"
ol=0; ob=0; lb=0
echo " $stat " | grep -q ' OL ' && ol=1
echo " $stat " | grep -q ' OB ' && ob=1
echo " $stat " | grep -q ' LB ' && lb=1
line="battery_voltage=${bv:-0} input_voltage=${iv:-0} output_voltage=${ov:-0} load=${ld:-0} temperature=${tp:-0} frequency=${fr:-0} status=${statc:-NA} ol=$ol ob=$ob lb=$lb"
ts="$(date +%s)000000000"
payload="{\"streams\":[{\"stream\":{\"job\":\"ups\",\"host\":\"1\",\"ups\":\"ted\"},\"values\":[[\"$ts\",\"$line\"]]}]}"
curl -s -m 5 -H 'Content-Type: application/json' -X POST "$LOKI" --data-binary "$payload" >/dev/null 2>&1
exit 0
