#!/bin/busybox sh
# BEFORE_INIT hook for agx-init12.sh. T8010/J71b ONLY.
# Real Fender + real RGX, remaining IO windows RAM-backed, EMPTY init program.
# Does not enqueue work. This tests hardware initialization, not rendering.
# Stage all three scripts to /run, then:
#   E0PA=0x201d00000 ESIZE=0x5000 BEFORE_INIT=/run/agx-init13.sh sh /run/agx-init12.sh
# No seq-markers.bin here: those marker writes are only safe against RAM!
[ "${E0PA:-}" = 0x201d00000 ] || { echo 'init13 requires real Fender' >&2; exit 1; }
[ -z "${SEQFILE:-}" ] || { echo 'init13 requires an empty program, not marker writes' >&2; exit 1; }
sh /run/fender-power-on.sh
# IO-table entry 3, RGX: PA 0x201000000, 128 KiB, device read/write.
e=$((0x2000 + 0x688))
put32 scratch $e 0x01000000
put32 scratch $((e + 4)) 2
put32 scratch $((e + 0xc)) 0x20000
put32 scratch $((e + 0x14)) 1
