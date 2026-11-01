#!/bin/sh
# Start seatd and Hyprland in the chroot with the fork's Zink; log to /tmp
# Mesa's kmsro pairs simpledrm (card0) with Zink on the GPU: no driver override
export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1
export XDG_RUNTIME_DIR=/run/user/0 LIBSEAT_BACKEND=seatd HOME=/root
mkdir -p $XDG_RUNTIME_DIR /root/.config/hypr; chmod 700 $XDG_RUNTIME_DIR
# Earlier runs are stopped by hypr-once.sh from outside (no procps in here);
# the config is ~/.config/hypr/hyprland.lua (hyprland-test.lua)
seatd -g root > /tmp/seatd.log 2>&1 &
sleep 1
# a test chroot: root, with the override Hyprland asks for
timeout -k 5 ${SECS:-40} Hyprland --i-am-really-stupid > /tmp/hypr.log 2>&1
echo "Hyprland exit $?"
