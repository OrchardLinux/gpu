#!/bin/busybox sh
# T8010/J71b only. Mirrors fw 0x16df2..0x16e94's state-1 request.
# Requires GFX PMGR domain already on and the experiment firmware running.
# Does not initialize RGX or prove rendering; never probes RGX before state=1.
set -eu
[ -d /sys/kernel/debug/apple_gpu_iop ] || { echo 'Load apple_gpu_iop first' >&2; exit 1; }
F=0x201d00000
state=$(devmem $((F + 0x1000)) 32)
if [ $((state & 0x1f)) -ne 1 ]; then
    devmem $((F + 0x1000)) 32 0x11
fi
i=0
while [ $i -lt 100 ]; do
    state=$(devmem $((F + 0x1000)) 32)
    [ $((state & 0x1f)) -eq 1 ] && break
    sleep 0.01
    i=$((i + 1))
done
[ $((state & 0x1f)) -eq 1 ] || { echo "Fender power request failed: $state" >&2; exit 1; }
echo "Fender state: $state"
printf 'Fender reset: '; devmem $((F + 0x2058)) 32
printf 'RGX CORE_ID: '; devmem 0x201000018 32
printf 'RGX CORE_REVISION: '; devmem 0x201000020 32
