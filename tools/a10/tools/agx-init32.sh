#!/bin/busybox sh
# BEFORE_INIT hook: actually power-cycle the RGX core, not just its IOP firmware.
. /run/agx-init31.sh
# The firmware is freshly booted but has not consumed init data or any job yet.
# fw 0x16df8..0x16e2a uses request 0x10 for target state 0.
devmem 0x201d01000 32 0x10
i=0
while [ $i -lt 100 ]; do
    state=$(devmem 0x201d01000 32)
    [ $((state & 0x1f)) -eq 0 ] && break
    sleep 0.01
    i=$((i + 1))
done
[ $((state & 0x1f)) -eq 0 ] || { echo "RGX power-down did not acknowledge: $state" >&2; exit 1; }
sh /run/fender-power-on.sh
printf 'MMU fault after core power-cycle: '; devmem 0x20100e150 64
