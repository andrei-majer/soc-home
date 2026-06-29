#!/bin/sh
# Read SATA SSD SMART on .15, push one logfmt line per device to Loki (.120).
# Labels {job="ssd", host="15", dev=<sda|sdb>, model=<...>}. Best-effort (Loki may be asleep).
# Requires root (smartctl device access). Run from systemd ssd-smart-loki.timer (10 min).
LOKI="http://192.168.1.120:3100/loki/api/v1/push"
HOST="15"
for d in sda sdb; do
  dev="/dev/$d"
  [ -b "$dev" ] || continue
  health=0
  smartctl -H "$dev" 2>/dev/null | grep -q PASSED && health=1
  model="$(smartctl -i "$dev" 2>/dev/null | awk -F': *' '/Device Model/{print $2; exit}' | tr ' ' '_')"
  line="$(smartctl -A "$dev" 2>/dev/null | awk -v h="$health" '
    $1==9   {poh=$10}
    $1==12  {pcc=$10}
    $1==173 {erase=$10}
    $1==194 {temp=$10}
    $1==202 {rem=$4; used=$10}
    $1==246 {lbaw=$10}
    $1==5   {ra=$10}
    $1==196 {rae=$10}
    $1==197 {pend=$10}
    $1==198 {unc=$10}
    $1==187 {ru=$10}
    END {
      poh+=0; pcc+=0; erase+=0; temp+=0; rem+=0; used+=0
      ra+=0; rae+=0; pend+=0; unc+=0; ru+=0; lbaw+=0
      tbw=lbaw*512/1e12
      printf "health=%d life_remaining_pct=%d life_used_pct=%d erase_count=%d temp_c=%d tbw_tb=%.2f reallocated=%d realloc_events=%d pending=%d uncorrectable=%d reported_uncorrect=%d power_on_hours=%d power_cycles=%d",
        h, rem, used, erase, temp, tbw, ra, rae, pend, unc, ru, poh, pcc
    }')"
  [ -n "$line" ] || continue
  ts="$(date +%s)000000000"
  payload="{\"streams\":[{\"stream\":{\"job\":\"ssd\",\"host\":\"$HOST\",\"dev\":\"$d\",\"model\":\"$model\"},\"values\":[[\"$ts\",\"$line\"]]}]}"
  curl -s -m 5 -H 'Content-Type: application/json' -X POST "$LOKI" --data-binary "$payload" >/dev/null 2>&1
done
exit 0
