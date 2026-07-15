#!/bin/sh
# Read SATA SSD SMART on .15, push one logfmt line per device to Loki (.120),
# plus one line per md RAID array. Best-effort (Loki may be asleep).
# Requires root (smartctl + sysfs). Run from systemd ssd-smart-loki.timer (10 min).
#
# Topology since the 2026-07-02 encrypted-RAID1 reinstall:
#   sdb + sdc = ADATA SU800 953GB  -> RAID1 (md126 root/home/vms, md127 /boot)
#   sda       = Crucial MX300 525GB -> single-disk LUKS backup (/mnt/backup)
# The two SSD families expose DIFFERENT SMART attribute IDs for life/writes, so
# the awk below coalesces per-model: Crucial/Micron (202,246,197,198,187,173)
# vs Silicon Motion / ADATA SU800 (169,241,160,199,167).
LOKI="http://192.168.1.20:3100/loki/api/v1/push"
HOST="15"

push() {  # $1 = stream-labels JSON fragment   $2 = logfmt line
  [ -n "$2" ] || return 0
  ts="$(date +%s)000000000"
  payload="{\"streams\":[{\"stream\":{$1},\"values\":[[\"$ts\",\"$2\"]]}]}"
  curl -s -m 5 -H 'Content-Type: application/json' -X POST "$LOKI" --data-binary "$payload" >/dev/null 2>&1
}

# --- per-disk SMART ---
for d in sda sdb sdc; do
  dev="/dev/$d"
  [ -b "$dev" ] || continue
  health=0
  smartctl -H "$dev" 2>/dev/null | grep -q PASSED && health=1
  model="$(smartctl -i "$dev" 2>/dev/null | awk -F': *' '/Device Model/{print $2; exit}' | tr ' ' '_')"
  line="$(smartctl -A "$dev" 2>/dev/null | awk -v h="$health" '
    # columns: $1=ID $4=VALUE(normalized) $10=RAW
    # --- common ---
    $1==9   {poh=$10}
    $1==12  {pcc=$10}
    $1==194 {temp=$10}
    $1==5   {ra=$10}
    $1==196 {rae=$10}
    # --- Crucial/Micron (MX300) ---
    $1==173 {erase=$10}
    $1==202 {rem=$4; used=$10}
    $1==246 {lbaw=$10}
    $1==197 {pend=$10}
    $1==198 {unc=$10}
    $1==187 {ru=$10}
    # --- Silicon Motion / ADATA SU800 ---
    $1==167 {erase_sm=$10}
    $1==169 {rem_sm=$10}
    $1==241 {hw32=$10}
    $1==160 {unc_sm=$10}
    $1==199 {crc=$10}
    END {
      poh+=0; pcc+=0; temp+=0; ra+=0; rae+=0
      # life remaining: Crucial 202 (normalized value), else SiMotion 169 (raw = pct remaining)
      if (rem=="" && rem_sm!="") { rem=rem_sm; used=100-rem_sm }
      rem+=0; used+=0
      # erase count: Crucial 173, else SiMotion average 167
      if (erase=="" && erase_sm!="") erase=erase_sm
      erase+=0
      # TBW: Crucial 246 (LBA*512B), else SiMotion 241 (Host_Writes in 32 MiB units)
      if (lbaw!="")      tbw=lbaw*512/1e12
      else if (hw32!="") tbw=hw32*33554432/1e12
      else               tbw=0
      # uncorrectable: Crucial 198, else SiMotion 160
      if (unc=="" && unc_sm!="") unc=unc_sm
      pend+=0; unc+=0; ru+=0; crc+=0
      printf "health=%d life_remaining_pct=%d life_used_pct=%d erase_count=%d temp_c=%d tbw_tb=%.2f reallocated=%d realloc_events=%d pending=%d uncorrectable=%d reported_uncorrect=%d crc_errors=%d power_on_hours=%d power_cycles=%d",
        h, rem, used, erase, temp, tbw, ra, rae, pend, unc, ru, crc, poh, pcc
    }')"
  push "\"job\":\"ssd\",\"host\":\"$HOST\",\"dev\":\"$d\",\"model\":\"$model\"" "$line"
done

# --- md RAID arrays (health + degraded/sync state) ---
for mdp in /sys/block/md*; do
  [ -d "$mdp/md" ] || continue          # skip partitions (mdXpN have no md/ dir)
  md="$(basename "$mdp")"
  degraded="$(cat "$mdp/md/degraded" 2>/dev/null)";       degraded="${degraded:-0}"
  raid_disks="$(cat "$mdp/md/raid_disks" 2>/dev/null)";   raid_disks="${raid_disks:-0}"
  sync_action="$(cat "$mdp/md/sync_action" 2>/dev/null)"; sync_action="${sync_action:-idle}"
  array_state="$(cat "$mdp/md/array_state" 2>/dev/null)"; array_state="${array_state:-unknown}"
  level="$(cat "$mdp/md/level" 2>/dev/null)";             level="${level:-unknown}"
  healthy=1; [ "$degraded" = "0" ] || healthy=0
  # logfmt values unquoted on purpose: push() injects the line raw into JSON, so
  # embedded double-quotes would break the payload (Loki 400). These fields never
  # contain spaces (idle/clean/active/raid1/...), so quotes aren't needed.
  line="healthy=$healthy degraded=$degraded raid_disks=$raid_disks sync_action=$sync_action array_state=$array_state level=$level"
  push "\"job\":\"mdraid\",\"host\":\"$HOST\",\"array\":\"$md\"" "$line"
done
exit 0
