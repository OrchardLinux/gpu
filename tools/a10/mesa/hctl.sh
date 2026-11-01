#!/bin/sh
# hyprctl against the running Hyprland in the chroot (device host side), as
# the demos use it: hctl.sh dispatch 'hl.dsp.window.center()', hctl.sh reload
chroot /run/sid sh -c 'export XDG_RUNTIME_DIR=/run/user/0 HOME=/root HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/0/hypr | head -1); exec timeout -k 2 5 hyprctl "$@"' hyprctl "$@" 2>&1
