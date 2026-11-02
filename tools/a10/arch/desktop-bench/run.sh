#!/bin/bash
# The desktop benchmark, run as the session user over SSH while the Omarchy A
# session is up: the same workload on whichever renderer Labwc runs (GPU or
# pixman). Prints one line per phase:
#   idle 20 s; foot printing for 20 s; Firefox (fresh profile) loading a
#   dashboard page, scrolling an article and animating 60 cards (20 s each).
# CPU is in seconds of user+system time, memory in MB.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
P=$(pgrep -u "$USER" -x labwc | head -1)
[ -n "$P" ] || { echo "no labwc session" >&2; exit 1; }
mapfile -d '' E < /proc/$P/environ
for v in "${E[@]}"; do case $v in WLR_RENDERER=*) R=${v#*=};; WAYLAND_DISPLAY=*) WD=${v#*=};; esac; done
WD=${WD:-wayland-0}
HZ=$(getconf CLK_TCK)
cpu() { local s=0; for p in "$@"; do read -r -a f < /proc/$p/stat 2>/dev/null && s=$((s + f[13] + f[14])); done; echo $s; }
procs() { pgrep -u "$USER" -f "$1" | tr '\n' ' '; }
avail() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }
shm() { awk '/^Shmem:/{print int($2/1024)}' /proc/meminfo; }
rss() { local s=0; for p in "$@"; do s=$((s + $(awk '/^Rss(Anon|Shmem):/{t+=$2} END{print t+0}' /proc/$p/status 2>/dev/null || echo 0))); done; echo $((s / 1024)); }
secs() { awk -v t="$1" -v h="$HZ" 'BEGIN{printf "%.1f", t / h}'; }
QS=$(procs '^qs ')
echo "renderer ${R:-?}; base: available $(avail) MB, shmem $(shm) MB, labwc rss $(rss $P) MB"

c0=$(cpu $P $QS); sleep 20; c1=$(cpu $P $QS)
echo "idle 20 s: labwc+shell cpu $(secs $((c1 - c0))) s, available $(avail) MB"

rm -f /tmp/bench-foot
c0=$(cpu $P)
env -i "${E[@]}" WAYLAND_DISPLAY=$WD foot -e sh -c 'i=0; end=$(( $(date +%s) + 20 )); while [ $(date +%s) -lt $end ]; do seq $i $((i + 999)); i=$((i + 1000)); done; echo $i > /tmp/bench-foot' >/dev/null 2>&1
c1=$(cpu $P)
echo "foot 20 s: $(cat /tmp/bench-foot 2>/dev/null || echo ?) lines, labwc cpu $(secs $((c1 - c0))) s"

out=/tmp/bench-results.jsonl; rm -f $out; rm -rf /tmp/bench-ff; touch /tmp/bench-start
python3 "$HERE/server.py" $out & srv=$!
sleep 1
s0=$(shm); a0=$(avail); c0=$(cpu $P); minav=$a0; peak=0; ffcpu=0
env -i "${E[@]}" WAYLAND_DISPLAY=$WD setsid -f firefox --new-instance --profile /tmp/bench-ff \
  "http://127.0.0.1:8765/load.html?next=scroll.html,anim.html" >/dev/null 2>&1
mkdir -p /tmp/bench-ff
for i in $(seq 1 180); do
  sleep 0.5
  a=$(avail); [ $a -lt $minav ] && minav=$a
  ff=$(procs firefox); r=$(rss $ff); [ $r -gt $peak ] && peak=$r
  c=$(cpu $ff); [ $c -gt $ffcpu ] && ffcpu=$c
  grep -q '"end"' $out 2>/dev/null && break
done
c1=$(cpu $P)
ds=$(( $(shm) - s0 ))
pkill -u "$USER" -x firefox; kill $srv; wait $srv 2>/dev/null
# /tmp is in RAM: the profile and the add-on copies Firefox unpacks there go
sleep 2; rm -rf /tmp/bench-ff; find /tmp -maxdepth 1 -user "$USER" \( -name 'tmp-*.xpi' -o -name '*-*-*-*-*.zip' \) -newer /tmp/bench-start -delete 2>/dev/null
python3 - "$out" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r['test'] == 'end':
        continue
    load = f", load {r['load']} ms" if r['test'] == 'load' else ''
    print(f"firefox {r['test']}: {r['fps']:.1f} fps, frame p50 {r['p50']:.1f} p95 {r['p95']:.1f} p99 {r['p99']:.1f} max {r['max']:.0f} ms, {r['jank']} frames over 25 ms{load}")
PY
echo "firefox total: firefox cpu $(secs $ffcpu) s, labwc cpu $(secs $((c1 - c0))) s, firefox rss peak $peak MB, shmem +$ds MB, min available $minav MB (from $a0)"
