#!/bin/busybox sh
# BEFORE_INIT: same mapped-branch/HALT task as 56, but force the PDS-related
# clock fields ON *before* the firmware kick. The earlier clock tests forced
# clocks only after a stall. Save originals for the wrapper to restore.
. /run/agx-init56.sh
devmem 0x201000080 64 > /run/clk57.x
devmem 0x201000000 64 > /run/clk57.c
oldx=$(cat /run/clk57.x)
oldc=$(cat /run/clk57.c)
newx=$(printf '0x%016x' $(((oldx & ~(3 << 22)) | (1 << 22))))
newc=$(printf '0x%016x' $(((oldc & ~(3 << 12)) | (1 << 12))))
devmem 0x201000080 64 "$newx"
devmem 0x201000000 64 "$newc"
sleep 1
echo "clk57 X=$newx C=$newc"
echo -n 'XTPLUS_STATUS '; devmem 0x201000088 64
echo -n 'CLK_STATUS    '; devmem 0x201000008 64
echo -n 'XTPLUS_CTRL   '; devmem 0x201000080 64
echo -n 'CLK_CTRL      '; devmem 0x201000000 64
