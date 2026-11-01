#!/bin/sh
# Frame-time benchmark for Hyprland with live blur (device host side, after
# setup-device.sh): starts Hyprland (hypr-start.sh), floats one window over
# the tiled ones and moves it, then reports the intervals between frames
# from Mesa's G9P_TRACE (a frame: renders less than 4 ms apart), and the
# GPU and CPU cost per frame:
#
#   hypr-bench.sh [moves N | glide | time N | profile] [demo|jade]
#     moves N   N moves (default 40), one every 0.25 s through hyprctl
#     glide     one move; give the style a slow windowsMove animation to
#               measure frames without hyprctl processes on the CPU
#     time N    N moves with G9P_SYNC=1 G9P_TIME=1: geometry and fragment
#               time per render (each render waited for, so not real speed)
#     profile   a glide under perf (tools/device/perf-install.sh first):
#               where Hyprland's CPU time goes, by library and symbol
#
# Also prints Hyprland's CPU time per frame (/proc, all threads). The result
# that matters for 60 Hz is the share of intervals under 20 ms.
MODE=${1:-moves}
N=${2:-40}
case $MODE in glide|profile) STYLE=${2:-jade} ;; *) STYLE=${3:-jade} ;; esac
ENVV=G9P_TRACE=1
[ "$MODE" = time ] && ENVV="G9P_SYNC=1 G9P_TIME=1"
DEMO_ENV=$ENVV sh /run/hypr-start.sh "$STYLE" > /dev/null 2>&1 || exit 2
H="sh /run/hctl.sh dispatch"
$H 'hl.dsp.window.float({ action = "toggle" })' > /dev/null
$H 'hl.dsp.window.resize({ x = 460, y = 320 })' > /dev/null
$H 'hl.dsp.window.move({ x = 40, y = 200 })' > /dev/null
sleep 2
[ "$(sh /run/hctl.sh clients | grep -c 'floating: 1')" = 1 ] || echo "warning: no floating window"
P=$(pidof Hyprland | awk '{ print $1 }')
L=/run/sid/tmp/hypr.log
n0=$(wc -l < "$L")
c0=$(awk '{ print $14 + $15 }' "/proc/$P/stat")
case $MODE in
moves|time)
    i=0
    while [ $i -lt "$N" ]; do
        $H "hl.dsp.window.move({ x = $((40 + (i % 2) * 260)), y = $((200 + (i % 2) * 400)) })" > /dev/null
        sleep 0.25
        i=$((i + 1))
    done ;;
glide)
    $H 'hl.dsp.window.move({ x = 300, y = 600 })' > /dev/null
    sleep 5 ;;
profile)
    LP=$(find /run/sid/opt/perf -name '*.so*' -exec dirname {} \; | sed 's|^/run/sid||' | sort -u | tr '\n' :)
    $H 'hl.dsp.window.move({ x = 300, y = 600 })' > /dev/null
    chroot /run/sid env LD_LIBRARY_PATH="$LP" timeout -k 5 20 /usr/local/bin/perf record -q \
        -F 2000 -p "$P" -o /tmp/perf.data -- sleep 4.5 ;;
*) echo "unknown mode $MODE"; exit 2 ;;
esac
c1=$(awk '{ print $14 + $15 }' "/proc/$P/stat")
tail -n +$((n0 + 1)) "$L" > /run/bench.log
killall -9 Hyprland seatd foot 2>/dev/null
grep "g9p: trace" /run/bench.log | awk -v ticks=$((c1 - c0)) '
    { t = $9 + 0; r++; if (p == "" || t - p >= 4) { if (f != "") { d = t - f; n++; s += d;
      if (d < 20) a++; else if (d < 35) b++; else c++ } f = t } p = t }
    END { if (n) printf "%d frame intervals, %d renders, mean %.1f ms: <20 ms %d, 20-35 %d, >35 %d; Hyprland CPU %.1f ms per frame\n",
                        n, r, s / n, a, b, c, ticks * 10 / (n + 1) }'
grep "g9p: time" /run/bench.log | awk '
    { for (i = 1; i <= NF; i++) { if ($i == "geometry") g += $(i + 1); if ($i == "fragment") f += $(i + 1) } n++ }
    END { if (n) printf "%d renders: geometry %.2f ms, fragment %.2f ms on average\n", n, g / n / 1000, f / n / 1000 }'
if [ "$MODE" = profile ]; then
    for s in dso dso,sym; do
        chroot /run/sid env LD_LIBRARY_PATH="$LP" timeout -k 5 120 /usr/local/bin/perf report \
            -i /tmp/perf.data --stdio --sort $s 2> /dev/null | grep -v '^#' | grep -v '^$' | head -25
    done
fi
