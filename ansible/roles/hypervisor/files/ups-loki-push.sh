#!/usr/bin/env bash
# Read the UPS and push one sample to Loki. Installed at /usr/local/bin/ups-loki-push.sh,
# fired every 30s by ups-loki.timer. Best-effort: if Loki is down the curl just fails.
set -uo pipefail
LOKI="http://192.168.1.20:3100/loki/api/v1/push"
out="$(upsc ted 2>/dev/null)" || exit 0
g(){ printf '%s\n' "$out" | awk -F': ' -v k="$1" '$1==k{print $2; exit}'; }

bv="$(g battery.voltage)"; iv="$(g input.voltage)"; ov="$(g output.voltage)"
ld="$(g ups.load)"; tp="$(g ups.temperature)"; fr="$(g input.frequency)"
stat="$(g ups.status)"; statc="${stat// /_}"
ol=0; ob=0; lb=0
case " $stat " in *" OL "*) ol=1;; esac
case " $stat " in *" OB "*) ob=1;; esac
case " $stat " in *" LB "*) lb=1;; esac

line="battery_voltage=${bv:-0} input_voltage=${iv:-0} output_voltage=${ov:-0} load=${ld:-0} temperature=${tp:-0} frequency=${fr:-0} status=${statc:-NA} ol=${ol} ob=${ob} lb=${lb}"
ts="$(date +%s%N)"
payload="$(printf '{"streams":[{"stream":{"job":"ups","host":"15","ups":"ted"},"values":[["%s","%s"]]}]}' "$ts" "$line")"
curl -s -m 5 -H 'Content-Type: application/json' -X POST "$LOKI" --data-binary "$payload" >/dev/null 2>&1 || true
