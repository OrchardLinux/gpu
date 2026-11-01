#!/bin/busybox sh
# BEFORE_INIT: 60's DOUTU-to-unmapped test, with PDS and USC clocks forced ON
# before the firmware kick. Earlier clock tests forced fields only after a stall.
. /run/agx-init60.sh
devmem 0x201000000 64 > /run/clk61.c
devmem 0x201000080 64 > /run/clk61.x
oldc=$(cat /run/clk61.c)
oldx=$(cat /run/clk61.x)
newc=$(printf '0x%016x' $(((oldc & ~(3 << 12)) | (1 << 12))))
newc=$(printf '0x%016x' $(((newc & ~(3 << 20)) | (1 << 20))))
newx=$(printf '0x%016x' $(((oldx & ~(3 << 18)) | (1 << 18))))
newx=$(printf '0x%016x' $(((newx & ~(3 << 22)) | (1 << 22))))
devmem 0x201000000 64 "$newc"
devmem 0x201000080 64 "$newx"
sleep 1
echo "clk61 X=$newx C=$newc"
echo -n 'XTPLUS_STATUS '; devmem 0x201000088 64
echo -n 'CLK_STATUS    '; devmem 0x201000008 64
echo -n 'XTPLUS_CTRL   '; devmem 0x201000080 64
echo -n 'CLK_CTRL      '; devmem 0x201000000 64
