#!/bin/busybox sh
# BEFORE_INIT hook: probe the compute work-ring and queue parser.
# Default RGX is RAM-backed, so command parsing cannot launch real GPU work.
# E0PA=0x201d00000 ESIZE=0x5000 BEFORE_INIT=/run/agx-init16.sh sh /run/agx-init12.sh
# Then set scratch+0x11028 (work ring 2 producer) to 1 and kick EP 0x21.
. /run/agx-init15.sh
if [ "${RGX_REAL:-0}" != 1 ]; then
    pa=$((S + 0x380000))
    put32 scratch $((0x2000 + 0x688)) $((pa & 0xffffffff))
    put32 scratch $((0x2000 + 0x68c)) $((pa >> 32))
fi
# Ring 2: 256 x 20-byte descriptors at VA 0x129000 (two pages).
put32 scratch 0x38 $((VA + 0x29000))
put32 scratch 0x29008 $((VA + 0x2b000)) # queue pointer
put32 scratch 0x2900c 2                # compute engine
put16 scratch 0x29010 1               # queue target head
# Queue object (>= 0x8c), state, command-pointer ring, status, compute command.
put32 scratch 0x2b000 $((VA + 0x2c000))
put32 scratch 0x2b004 $((VA + 0x2d000))
put32 scratch 0x2b088 $((VA + 0x2e000))
put32 scratch 0x2c050 256
put32 scratch 0x2d000 $((VA + 0x2f000))
put32 scratch 0x2f000 3                # compute command (format still being decoded)
