#!/bin/sh
# Reload the GPU driver (host side of the device; after a hang)
for p in $(fuser /dev/dri/renderD128 2>/dev/null); do kill -9 $p; done
for i in 1 2 3; do rmmod powervr 2>/dev/null && break; sleep 2; done
# A process stuck in the driver (state D after a hang) keeps the module:
# then the old, possibly hung GPU instance stays, and only a reboot helps
if lsmod | grep -q '^powervr '; then
    echo "GPU module NOT reloaded: still in use ($(lsmod | awk '$1 == "powervr" {print $3}') users); reboot the device"
else
    modprobe powervr exp_hw_support=1 && echo "GPU module reloaded"
fi
