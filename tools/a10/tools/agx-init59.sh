#!/bin/busybox sh
# BEFORE_INIT: DOUTU reachability test. Point the PDS DOUTU task-control
# constant at an UNMAPPED USC code page (0x300004000). If the DOUTU executes,
# the USC instruction fetch must fault at that address. DOUTU_WORD selects the
# cc/end encoding: 0xf8000002 (cc=0,end=1) or 0xfc000002 (cc=1,end=1).
. /run/agx-init46.sh
put32 scratch 0x84800 0x00004000
put32 scratch 0x84804 0x00000003
put32 scratch 0x84808 0
put32 scratch 0x8480c 0
put32 scratch 0x87f00 ${DOUTU_WORD:-0xf8000002}
put32 scratch 0x87f04 0xd3000000
put32 scratch 0x60000 0x00000004
put32 scratch 0x60004 0x00000088
put32 scratch 0x60008 0x00003f00
put32 scratch 0x6000c 0x00000000
put32 scratch 0x60010 0x00000000
put32 scratch 0x60014 0x00000000
put32 scratch 0x60018 0x40000000
put32 scratch 0x6001c 0x80000000
