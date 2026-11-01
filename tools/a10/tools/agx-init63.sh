#!/bin/busybox sh
# BEFORE_INIT: DOUTU to a native G9P USC program. The code is the empty kernel
# compiled offline by Apple's Metal toolchain for applegpu_g9p (metal-tt), so
# unlike 58's PCO NOP it is valid A10 USC code. USC offset 0x2000 ->
# 0x300002000 (scratch+0x86000), inside the mapped PDS/code page.
USC_OFF=0x00002000
. /run/agx-init62.sh
# applegpu_g9p empty_kernel __text, 0x42 bytes: 00 01 40 01 00 00, NOP
# padding (00 c0), end (00 80).
put32 scratch 0x86000 0x01400100
put32 scratch 0x86004 0xc0000000
o=0x86008
while [ $((o)) -lt $((0x86040)) ]; do
    put32 scratch $o 0xc000c000
    o=$((o + 4))
done
put32 scratch 0x86040 0x00008000
put32 scratch 0x86044 0
put32 scratch 0x86048 0
put32 scratch 0x8604c 0
