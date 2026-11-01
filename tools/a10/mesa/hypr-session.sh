#!/bin/sh
# One Hyprland session of SECS seconds (default 60), checked every 10 s for GPU
# job timeouts, then stopped with hyprctl dispatch exit; prints when the first
# timeout appeared and how many renders G9P_TRACE logged. BUSY=1 opens a
# second foot window that prints without pause (it compiles the border
# shader, which fails: rendering then stops). Device host side.
killall -9 Hyprland seatd foot 2>/dev/null; sleep 1; dmesg -c >/dev/null
chroot /run/sid sh -c "export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 XDG_RUNTIME_DIR=/run/user/0 LIBSEAT_BACKEND=seatd HOME=/root; rm -rf /run/user/0/hypr; mkdir -p /run/user/0; chmod 700 /run/user/0; seatd -g root >/tmp/seatd.log 2>&1 & sleep 1; G9P_TRACE=1 G9P_DEBUG=1 Hyprland --i-am-really-stupid >/tmp/hypr.log 2>&1 &" &
first=""
# BUSY=1: a foot window printing without pause, for constant redraws
if [ -n "$BUSY" ]; then sleep 4; chroot /run/sid sh -c "XDG_RUNTIME_DIR=/run/user/0 HOME=/root hyprctl dispatch exec \"foot sh -c 'while :; do date; done'\"" >/dev/null 2>&1; fi
for t in $(seq 10 10 ${SECS:-60}); do sleep 10; [ -z "$first" ] && dmesg | grep -q "timed out" && first="during session (by ${t}s)"; done
chroot /run/sid sh -c "XDG_RUNTIME_DIR=/run/user/0 HOME=/root hyprctl dispatch exit" >/dev/null 2>&1
for t in 2 4 6 8 10 12; do sleep 2; [ -z "$first" ] && dmesg | grep -q "timed out" && first="after exit (+${t}s)"; done
echo "${first:-no hang}; renders $(grep -c "g9p: trace" /run/sid/tmp/hypr.log)"
dmesg | grep -m1 "hang:" | sed "s/.*hang: //" | cut -c1-90
killall -9 Hyprland seatd foot 2>/dev/null
