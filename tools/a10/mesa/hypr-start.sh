#!/bin/sh
# Start Hyprland on the iPad's screen in one of the demo styles and return
# once it is up (device host side; hypr-demo.sh and hypr-bench.sh use it):
#
#   hypr-start.sh [demo|jade]
#     demo   hyprland-demo.lua, every effect, over demo-wallpaper.py's image
#     jade   hyprland-jade.lua, Omarchy's Jade Horse look (jade-wallpaper.sh)
# DEMO_ENV passes variables to Hyprland (G9P_* debugging, MESA.md); the log
# is /run/sid/tmp/hypr.log
STYLE=${1:-demo}
case $STYLE in
demo|jade) ;;
*) echo "unknown style $STYLE"; exit 2 ;;
esac
killall -9 Hyprland seatd foot 2>/dev/null; sleep 1
# Hyprland draws wall0-2.png when its logo is on (the configs set that)
for i in 0 1 2; do cp "/run/sid/root/wall-$STYLE.png" "/run/sid/usr/share/hypr/wall$i.png"; done
chroot /run/sid sh -c 'export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 XDG_RUNTIME_DIR=/run/user/0 LIBSEAT_BACKEND=seatd HOME=/root LANG=C.UTF-8
    rm -rf $XDG_RUNTIME_DIR/hypr; mkdir -p $XDG_RUNTIME_DIR; chmod 700 $XDG_RUNTIME_DIR
    seatd -g root > /tmp/seatd.log 2>&1 &
    sleep 1
    '"$DEMO_ENV"' Hyprland --i-am-really-stupid -c /root/'"$STYLE"'.lua > /tmp/hypr.log 2>&1 &' &
sleep 8
# Hyprland caches the blurred wallpaper once the first translucent windows
# are up, and keeps it: the startup windows come before its wallpaper has
# loaded (a 4.6 MB PNG), so the cache holds the empty screen. A reload
# redoes it (blur settings invalidate the cache).
sh /run/hctl.sh reload > /dev/null
sleep 2
