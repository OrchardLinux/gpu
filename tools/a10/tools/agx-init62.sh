#!/bin/busybox sh
# BEFORE_INIT: DOUTU reachability with a correctly encoded task control.
# 58-61 wrote the full VA into DOUTU src0, so the high word 0x3 landed in the
# sample-rate bits and no temps were requested. Rogue src0 is a 32-bit offset
# from the USC code base (bits 31:2), temps in 4-register blocks at bit 35.
# The kext's fixed window P+0x18 = 0x300000000 is the assumed USC code base.
# Default: offset 0x4000 -> 0x300004000, the unmapped page after the PDS page.
# A USC fetch fault there confirms DOUTU and the code base; a fault elsewhere
# reveals the base.
. /run/agx-init46.sh
put32 scratch 0x84800 ${USC_OFF:-0x00004000}
put32 scratch 0x84804 ${SRC0_HI:-0x00000008}  # temps = 1 block (bit 35)
put32 scratch 0x84808 0
put32 scratch 0x8480c 0
# DOUTU src0 = const 0. DOUT bits: CC = 27, END = 26 (Mesa pvr_rogue_pds_defs.h),
# so 0xf8000002 is cc=1/end=0, 0xfc000002 cc=1/end=1, and Apple's own compute
# PDS (captured under iOS) uses 0xf4000002: end=1, cc=0. HALT fallback.
put32 scratch 0x87f00 ${DOUTU_WORD:-0xf8000002}
put32 scratch 0x87f04 0xd3000000
# PDS kernel as 58: one data chunk, all clusters, USC sequential dependency,
# code 0x3f00, data 0x800, 1x1x1 groups, max 8 instances.
put32 scratch 0x60000 0x00000004
put32 scratch 0x60004 ${SD_TYPE:-0x00000088}
put32 scratch 0x60008 0x00003f00
put32 scratch 0x6000c 0x00000000
put32 scratch 0x60010 0x00000000
put32 scratch 0x60014 0x00000000
put32 scratch 0x60018 0x40000000
put32 scratch 0x6001c 0x80000000
