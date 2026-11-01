#!/bin/busybox sh
# BEFORE_INIT: first PDS -> USC kick. The PDS program is DOUTU + HALT, and
# the DOUTU src0 constant points at a 4-byte PCO control NOP with END.
# PDS page: VA 0x300000000 -> scratch+0x84000 (16 KiB).
#   data 0x800  -> 0x300000800 (DOUTU task-control constant)
#   USC  0x2000 -> 0x300002000 (PCO control NOP with END)
#   code 0x3f00 -> 0x300003f00 (DOUTU, HALT)
. /run/agx-init46.sh
# DOUTU src0 = USC execution address 0x300002000 (64-bit at data offset 0x800).
put32 scratch 0x84800 0x00002000
put32 scratch 0x84804 0x00000003
put32 scratch 0x84808 0
put32 scratch 0x8480c 0
# PCO control NOP with miscctl/end set, packed by the local pco_isa.h generator.
# Bytes: 01 80 ee 00. Pad the rest of the 16-byte fetch with zero.
put32 scratch 0x86000 0x00ee8001
put32 scratch 0x86004 0
put32 scratch 0x86008 0
put32 scratch 0x8600c 0
# DOUTU src0=constant 0, end=1; HALT fallback.
put32 scratch 0x87f00 0xfc000002
put32 scratch 0x87f04 0xd3000000
# PDS kernel: one data chunk, ALL clusters, no fence, USC sequential dependency,
# code 0x3f00, data 0x800, 1x1x1 groups, max 8 instances.
put32 scratch 0x60000 0x00000004
put32 scratch 0x60004 0x00000088
put32 scratch 0x60008 0x00003f00
put32 scratch 0x6000c 0x00000000
put32 scratch 0x60010 0x00000000
put32 scratch 0x60014 0x00000000
put32 scratch 0x60018 0x40000000
put32 scratch 0x6001c 0x80000000
