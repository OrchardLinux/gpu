#!/bin/sh
# Which way of stopping Hyprland leaves its last frame unfinished on the GPU
# (MESA.md "The hang, narrowed"). Starts seatd and Hyprland in the chroot,
# lets it render, stops it one way, then reports the kernel's job timeouts
# and processes stuck in the driver. Device host side:
#
#   hypr-stop-test.sh exit|term|kill|seatd [SECONDS]
#     exit   hyprctl dispatch exit (Hyprland's own shutdown), seatd stays
#     term   SIGTERM to Hyprland, seatd stays
#     kill   SIGKILL to Hyprland, seatd stays
#     seatd  SIGKILL to seatd, then to Hyprland (as hypr-once.sh did)
MODE=$1
SECS=${2:-15}
killall -9 Hyprland seatd foot 2>/dev/null
sleep 1
dmesg -c > /dev/null
chroot /run/sid sh -c '
    export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 XDG_RUNTIME_DIR=/run/user/0 LIBSEAT_BACKEND=seatd HOME=/root
    rm -rf $XDG_RUNTIME_DIR/hypr; mkdir -p $XDG_RUNTIME_DIR; chmod 700 $XDG_RUNTIME_DIR
    seatd -g root > /tmp/seatd.log 2>&1 &
    sleep 1
    Hyprland --i-am-really-stupid > /tmp/hypr.log 2>&1 &
' &
sleep "$SECS"
case $MODE in
exit)  chroot /run/sid sh -c 'XDG_RUNTIME_DIR=/run/user/0 HOME=/root hyprctl dispatch exit' > /dev/null 2>&1 ;;
term)  killall -TERM Hyprland ;;
kill)  killall -9 Hyprland ;;
seatd) killall -9 seatd; killall -9 Hyprland ;;
*)     echo "unknown mode $MODE"; exit 2 ;;
esac
sleep 12
stuck=$(ps -o stat,comm | awk '$1 ~ /^D/ {print $2}' | grep -v kworker | sort | uniq -c | tr '\n' ' ')
echo "$MODE: timeouts $(dmesg | grep -c 'timed out'); stuck: ${stuck:-none}"
dmesg | grep -m1 'hang:' | sed 's/.*hang: //' | cut -c1-120
killall -9 Hyprland seatd foot 2>/dev/null
