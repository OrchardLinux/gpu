#!/bin/busybox sh
# BEFORE_INIT hook: init14 plus cache-index pointers and the empty control ring.
# E0PA=0x201d00000 ESIZE=0x5000 BEFORE_INIT=/run/agx-init15.sh sh /run/agx-init12.sh
# Kick EP 0x21 WITHOUT making ring indices unequal. No jobs are enqueued.
. /run/agx-init14.sh
# 0x41b uses MAIR index 2 (0xf4: inner non-cacheable), unlike 0x11b's
# index 0 (0xff: write-back). Indices change at runtime from the AP.
put16 mem $((DESC + 0xe)) 0
# fw 0x200ec loads X+0xd0 -> cache index, X+0xd8 -> control ring data.
# fw 0x1ab3e synchronizes 256 entries of 32 bytes, then 0x20104 updates cache idx.
# All 13 rings have a third index pointer between the previously known two.
i=0
while [ $i -lt 13 ]; do
    put32 scratch $((0x10 + 0x10 * i)) $((VA + 0x11004 + 0x10 * i))
    i=$((i + 1))
done
put32 scratch 0xd8 $((VA + 0x27000))
