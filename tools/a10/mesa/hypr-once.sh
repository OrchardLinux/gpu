#!/bin/sh
# One bounded Hyprland run in the chroot, then cleanup and a verified GPU
# reload (device host side): hypr-once.sh [SECONDS]. The G9P_* debugging
# variables of the Vulkan driver (MESA.md "Hyprland renders") pass through;
# the kernel's GPU messages are kept in /run/hypr-dmesg.txt.
SECS=${1:-30}
G9P=$(env | grep '^G9P_' | tr '\n' ' ')
killall -9 Hyprland seatd foot 2>/dev/null; sleep 1
chroot /run/sid sh -c "rm -rf /run/user/0/hypr; $G9P SECS=$SECS timeout -k 5 $((SECS + 20)) /usr/local/bin/hypr-run"
# busybox killall from outside: the chroot has no procps
killall -9 Hyprland seatd foot 2>/dev/null; sleep 1
echo "GPU job timeouts: $(dmesg | grep -c 'timed out')"
chroot /run/sid sh -c 'grep -E "g9p: render|g9p: G9P|out of registers|ZINK|MESA: error" /tmp/hypr.log | sort | uniq -c | sort -rn | head -12'
for i in 1 2 3; do rmmod powervr 2>/dev/null && break; sleep 2; done
# A process stuck in the driver (state D after a hang) keeps the module:
# then the old, possibly hung GPU instance stays, and only a reboot helps
if lsmod | grep -q '^powervr '; then
    echo "GPU module NOT reloaded: still in use ($(lsmod | awk '$1 == "powervr" {print $3}') users); reboot the device"
else
    modprobe powervr exp_hw_support=1 && echo "GPU module reloaded"
fi
dmesg | grep -i "powervr\|apple\|gpu" > /run/hypr-dmesg.txt; dmesg -c > /dev/null
