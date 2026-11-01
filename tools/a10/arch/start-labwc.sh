#!/bin/sh
# Labwc with Omarchy A's shell (Quickshell) and a scrolling foot, in the
# Arch root of setup-device.sh, rendering on the GPU or as Omarchy A does
# today, then numbers for the run (device host side):
#
#   sh /run/start-labwc.sh [gpu|cpu] [SECONDS]      (ROT=90 turns the output)
#
# gpu: wlroots' GLES2 renderer on the GPU's render node (EGL and GBM from
#      Arch's Mesa, Zink on the fork's Vulkan driver); Qt Quick on OpenGL.
# cpu: Omarchy A's session today (pixman, Qt Quick software, software GL).
# Prints Labwc's and Quickshell's CPU time, in gpu mode the intervals of
# Labwc's renders (G9P_TRACE), and saves /run/arch/tmp/shot.png (grim).
MODE=${1:-gpu}
SECS=${2:-15}
killall -9 labwc qs quickshell foot seatd 2>/dev/null; sleep 1
for c in /sys/class/drm/card*; do
    [ "$(basename "$(readlink "$c/device/driver" 2>/dev/null)")" = apple-adbe ] && KMS=/dev/dri/$(basename "$c")
done
COMMON="XDG_RUNTIME_DIR=/run/user/0 HOME=/root LIBSEAT_BACKEND=seatd XDG_SESSION_TYPE=wayland
    XDG_CURRENT_DESKTOP=labwc QT_QPA_PLATFORM=wayland OMARCHY_PATH=/opt/omarchy OMARCHY_TOUCH_MODE=1
    PATH=/opt/omarchy/bin:/usr/bin WLR_DRM_DEVICES=${KMS:-/dev/dri/card1}"
case $MODE in
gpu) RENDER="WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 MESA_LOADER_DRIVER_OVERRIDE=zink
         PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 G9P_TRACE=1" ;;
cpu) RENDER="WLR_RENDERER=pixman QT_QUICK_BACKEND=software LIBGL_ALWAYS_SOFTWARE=1" ;;
*) echo "mode: gpu or cpu" >&2; exit 2 ;;
esac
cat > /run/arch/root/.config/labwc/autostart <<'EOF'
qs -p /opt/omarchy/shell/shell.qml > /tmp/qs.log 2>&1 &
foot sh -c 'while :; do ls -lR /usr/share; done' > /tmp/foot.log 2>&1 &
EOF
chroot /run/arch sh -c "export $COMMON $RENDER
    rm -rf /run/user/0/wayland-*
    seatd -g root > /tmp/seatd.log 2>&1 &
    sleep 1
    labwc > /tmp/labwc.log 2>&1 &" &
sleep 10
W="XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0"
if [ -n "${ROT:-}" ]; then
    out=$(chroot /run/arch env $W wlr-randr | sed -n '1s/ .*//p')
    chroot /run/arch env $W wlr-randr --output "$out" --transform "$ROT"
    sleep 2
fi
cpu() { for n in labwc quickshell qs; do for p in $(pidof $n); do awk '{ s += $14 + $15 } END { printf "%d ", s }' /proc/$p/stat; done; done; }
n0=$(wc -l < /run/arch/tmp/labwc.log)
c0=$(cpu)
sleep "$SECS"
c1=$(cpu)
chroot /run/arch env $W grim /tmp/shot.png 2>/dev/null
echo "$MODE${ROT:+ rotated $ROT}: CPU ticks (labwc, shell) $c0-> $c1over ${SECS}s"
tail -n +$((n0 + 1)) /run/arch/tmp/labwc.log | grep "g9p: trace" | awk '
    { t = $9 + 0; r++; if (p == "" || t - p >= 4) { if (f != "") { d = t - f; n++; s += d;
      if (d < 20) a++; else if (d < 35) b++; else c++ } f = t } p = t }
    END { if (n) printf "%d frame intervals, %d renders, mean %.1f ms: <20 ms %d, 20-35 %d, >35 %d\n", n, r, s / n, a, b, c }'
grep -i -m5 "error\|failed\|warn" /run/arch/tmp/labwc.log /run/arch/tmp/qs.log | grep -v "g9p: trace" | cut -c1-160
killall -9 labwc qs quickshell foot seatd 2>/dev/null
