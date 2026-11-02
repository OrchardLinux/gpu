#!/bin/bash
# The video phase of the desktop benchmark (see run.sh), run the same way:
# Firefox (fresh profile) plays VP9 720p, H.264 720p and VP9 1080p clips
# (make-clips.sh writes them to video/) for 20 s each, as a video site does.
# Prints frames shown and dropped per clip, then CPU and memory.
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


out=/tmp/bench-results.jsonl; rm -f $out; rm -rf /tmp/bench-ff; touch /tmp/bench-start
python3 "$HERE/server.py" $out & srv=$!
sleep 1
s0=$(shm); a0=$(avail); c0=$(cpu $P); minav=$a0; peak=0; ffcpu=0
env -i "${E[@]}" WAYLAND_DISPLAY=$WD setsid -f firefox --new-instance --profile /tmp/bench-ff \
  "http://127.0.0.1:8765/video.html" >/dev/null 2>&1
mkdir -p /tmp/bench-ff
for i in $(seq 1 240); do
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
    if 'error' in r:
        print(f"firefox {r['test']}: {r['error']}")
        continue
    print(f"firefox {r['test']} {r['w']}x{r['h']}: {r['fps']:.1f} fps shown, {r['dropped']} of {r['total']} frames dropped")
PY
echo "video total: firefox cpu $(secs $ffcpu) s, labwc cpu $(secs $((c1 - c0))) s, firefox rss peak $peak MB, shmem +$ds MB, min available $minav MB (from $a0)"
