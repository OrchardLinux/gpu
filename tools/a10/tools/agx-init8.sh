#!/bin/busybox sh
# AGX init, step 8: + power-state struct (>= 0x41f8 bytes) on its own 8 pages at VA 0x130000. Fixed firmware mappings live at
# VA 0x00100000 (one mem-desc entry, 64 KiB of scratch). Reloads the driver
# (firmware power cycle) first.
set -eu
D=/sys/kernel/debug/apple_gpu_iop
mountpoint -q /sys/kernel/debug 2>/dev/null || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
rmmod apple_gpu_iop 2>/dev/null || true
insmod /run/apple_gpu_iop.ko
W=$(($(dmesg | grep 'GFX firmware up, window' | tail -1 | sed 's/.*window //')))
S=$(($(dmesg | grep 'scratch 0x' | tail -1 | sed 's/.*scratch //; s/ .*//')))

put32() {   # put32 FILE OFFSET VALUE
    v=$(($3))
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $((v & 255)) $(((v >> 8) & 255)) $(((v >> 16) & 255)) $(((v >> 24) & 255)))" |
        dd of=$D/$1 bs=1 seek=$(($2)) conv=notrunc 2>/dev/null
}
put16() {
    v=$(($3))
    printf "$(printf '\\%03o\\%03o' $((v & 255)) $(((v >> 8) & 255)))" | dd of=$D/$1 bs=1 seek=$(($2)) conv=notrunc 2>/dev/null
}

INIT=0x98000; DESC=0x9c000      # window offsets (by PA)
VA=0x00100000                   # scratch[0, 64 KiB) at this firmware VA
RREG=0x200000                   # R = scratch + 0x200000 (by PA)
R=$((S + RREG))
SHARED=$((RREG + 0x110000))     # firmware page 0x30000 remapped here
printf 'window %#x scratch %#x R %#x\n' $W $S $R

# mem-desc entry 0: VA 0x00100000 -> scratch, 16 pages, flags 0x2
put32 mem $((DESC + 0x0)) $VA
put32 mem $((DESC + 0x4)) $((S >> 12))
put32 mem $((DESC + 0x8)) 0
put16 mem $((DESC + 0xc)) 56
put16 mem $((DESC + 0xe)) 0x0002
# scratch: X (VA+0) -> P (VA+0x2000); P+0x640 = R
put32 scratch 0x0 $((VA + 0x2000))   # X[0] = P
put32 scratch 0x4 $((VA + 0x6000))   # X[1] = Q
put32 scratch 0x8 $((VA + 0x7000))   # X[2] = Z
# ring i: X+0xc+0x10i -> index A, X+0x14+0x10i -> index B (VA 0x111000.., zero = idle)
i=0
while [ $i -lt 13 ]; do
    put32 scratch $((0xc + 0x10 * i)) $((VA + 0x11000 + 0x10 * i))
    put32 scratch $((0x14 + 0x10 * i)) $((VA + 0x11008 + 0x10 * i))
    i=$((i + 1))
done
# remaining X pointers, one zero page each (VA 0x118000..0x122000)
va=$((VA + 0x18000))
for off in 0xe4 0xe8 0xec 0xf0 0x134 0x138 0x13c 0x140 0x188 0x1ec 0x1fc; do
    put32 scratch $off $va
    va=$((va + 0x1000))
done
# V (init+0x9c, VA+0x8000): mapping ring control block and entries
put32 scratch $((0x8000 + 0x455c)) $((VA + 0x24000))
put32 scratch $((0x8000 + 0x4560)) $((VA + 0x25000))
# X+0x301 (unaligned) -> power-state struct VA 0x130000 (8 pages)
printf '\000\000\023\000' | dd of=$D/scratch bs=1 seek=$((0x301)) conv=notrunc 2>/dev/null
put32 scratch $((0x2000 + 0x640)) $((R & 0xffffffff))
put32 scratch $((0x2000 + 0x644)) $((R >> 32))
# init page
put32 mem $((INIT + 0x18)) $VA
put32 mem $((INIT + 0x1c)) $((VA + 0x4000))
put32 mem $((INIT + 0x8c)) $(((W + DESC) & 0xffffffff))
put32 mem $((INIT + 0x90)) $(((W + DESC) >> 32))
put32 mem $((INIT + 0x94)) 1
put32 mem $((INIT + 0x98)) $((VA + 0x5000))
put32 mem $((INIT + 0x9c)) $((VA + 0x8000))
put32 mem $((INIT + 0xa0)) $((VA + 0x10000))

b=$(dmesg | wc -l)
echo "20 $(printf %x $(((0x81 << 48) | (W + INIT))))" > $D/send
sleep ${WAIT:-3}
dmesg | tail -n +$((b + 1)) | grep -E 'ep 0x|crashed' || true
strings -n 6 $D/crashlog 2>/dev/null | grep -v -E 'RTKit-|^rtk_|^agx_' || true
rd32() { dd if=$D/$1 bs=4 skip=$(($2 / 4)) count=1 2>/dev/null | hexdump -e '1/4 "%08x"'; }
echo "ready: shared+0 = $(rd32 scratch $SHARED), U+0x14 = $(rd32 scratch $((0x5000 + 0x14)))"
echo "power path: A0+0x1b8 = $(rd32 scratch $((0x10000 + 0x1bc)))$(rd32 scratch $((0x10000 + 0x1b8)))"
echo "shared page (R+0x110000), first 0x140 bytes:"
dd if=$D/scratch bs=4096 skip=$((SHARED / 4096)) count=1 2>/dev/null | hexdump -C | head -24
