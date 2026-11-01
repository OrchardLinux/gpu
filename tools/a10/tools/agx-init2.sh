#!/bin/busybox sh
# AGX init, step 2 (FENDER.md section 9), with all firmware-visible memory in
# the driver's own buffers. Reloads the driver (firmware power cycle) first.
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

INIT=0x98000; DESC=0x9c000          # window offsets
XPAGE=0x0; PCTX=0x4000; RREG=0x200000  # scratch offsets
VA=${VA:-0x40000000}; FLAGS=${FLAGS:-0x0002}
R=$((S + RREG))
printf 'window %#x scratch %#x  init %#x desc %#x  X %#x P %#x R %#x\n' \
    $W $S $((W + INIT)) $((W + DESC)) $((S + XPAGE)) $((S + PCTX)) $R

# mem-desc entry 0: VA 0x40000000 -> scratch, 8 pages, flags 0x2
put32 mem $((DESC + 0x0)) $VA
put32 mem $((DESC + 0x4)) $(((S + XPAGE) >> 12))
put32 mem $((DESC + 0x8)) 0
put16 mem $((DESC + 0xc)) 8
put16 mem $((DESC + 0xe)) $FLAGS
# init page
put32 mem $((INIT + 0x18)) $VA
put32 mem $((INIT + 0x8c)) $(((W + DESC) & 0xffffffff))
put32 mem $((INIT + 0x90)) $(((W + DESC) >> 32))
put32 mem $((INIT + 0x94)) 1
# X -> P, P+0x640 = R
put32 scratch $XPAGE $((VA + PCTX))
put32 scratch $((PCTX + 0x640)) $((R & 0xffffffff))
put32 scratch $((PCTX + 0x644)) $((R >> 32))

b=$(dmesg | wc -l)
echo "20 $(printf %x $(((0x81 << 48) | (W + INIT))))" > $D/send
sleep 3
dmesg | tail -n +$((b + 1)) | grep -E 'ep 0x|crashed' || true
strings -n 6 $D/crashlog 2>/dev/null | grep -v -E 'RTKit-|^rtk_|^agx_' || true
n=$(dd if=$D/scratch bs=4096 skip=$(((RREG + 0x110000) / 4096)) count=1 2>/dev/null | tr -d '\000' | wc -c)
echo "R+0x110000 page: $n nonzero bytes (expect ~0xd70 copied)"
