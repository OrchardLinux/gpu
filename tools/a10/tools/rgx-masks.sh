#!/bin/busybox sh
# Writable-bit masks of RGX configuration registers: with powervr loaded and
# the GPU idle, write all-ones to each register, read back, restore. Skips the
# kick and status registers (0x400, 0x430, 0xf00, 0xf04).
#
#   sh /run/rgx-masks.sh               # geometry and PM registers
#   sh /run/rgx-masks.sh START END ... # word ranges, e.g. 0x600 0x700
base=0x201000000
probe() {
    a=$((base + $1)); old=$(devmem $a 32)
    devmem $a 32 0xffffffff; ones=$(devmem $a 32)
    devmem $a 32 0; zero=$(devmem $a 32)
    devmem $a 32 $old
    [ "$ones" != "0x00000000" -o "$zero" != "0x00000000" ] && printf "%x ones=%s zero=%s\n" $1 $ones $zero
}
range() {
    o=$(($1)); while [ $o -lt $(($2)) ]; do
        case $o in $((0x400))|$((0x430))|$((0xf00))|$((0xf04))) ;; *) probe $o ;; esac
        o=$((o + 4))
    done
}
if [ $# -gt 0 ]; then
    while [ $# -ge 2 ]; do range $1 $2; shift 2; done
    exit
fi
range 0x404 0x480
range 0xc00 0xd40
for o in 0x210 0x214 0x218 0x21c 0x220 0x224 0x230 0x234 0x240 0x244 0x248 0x24c 0x2d8 0x2dc 0x390 0x394; do probe $((o)); done
