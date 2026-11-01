#!/bin/busybox sh
# Crash-driven COMPUTE PARSER probe. RGX writes go ONLY to RAM, never the GPU.
# The known fixed-init self-clearing bits are emulated in that RAM.
set -eu
export E0PA=0x201d00000 ESIZE=0x5000 RGX_REAL=0
export BEFORE_INIT=${HOOK:-/run/agx-init18.sh}
. /run/agx-init12.sh
put32 scratch 0x11028 1
echo '21 83000000000000' > "$D/send"
i=0
while [ $i -lt 12 ]; do
    for off in 0x11f00 0xcd8 0xcb8; do
        put32 scratch $((0x380000 + off)) 0
    done
    sleep 0.05
    i=$((i + 1))
done
echo 'Compute-ring indices (consumer/cache/producer):'
dd if="$D/scratch" bs=1 skip=$((0x11020)) count=16 2>/dev/null | hexdump -C
echo 'Queue object:'
dd if="$D/scratch" bs=1 skip=$((0x2b000)) count=144 2>/dev/null | hexdump -C
echo 'First scheduling entry:'
dd if="$D/scratch" bs=1 skip=$((0x50000)) count=44 2>/dev/null | hexdump -C
wc -c "$D/crashlog"
strings "$D/crashlog" | head -30
# Preserve RAM register state for offline analysis; no real GPU reads here.
dd if="$D/scratch" of=/run/compute-registers.bin bs=4096 skip=$((0x380000 / 4096)) count=32 2>/dev/null
