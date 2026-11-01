#!/bin/busybox sh
# BEFORE_INIT: DOUTU reachability test with a selectable PDS sequential
# dependency. k1 defaults to sd_type NONE (0x80) so the PDS code executes
# independently, unlike the sd_type USC variant in 59.
. /run/agx-init46.sh
put32 scratch 0x84800 0x00004000
put32 scratch 0x84804 0x00000003
put32 scratch 0x84808 0
put32 scratch 0x8480c 0
put32 scratch 0x87f00 ${DOUTU_WORD:-0xf4000002}
put32 scratch 0x87f04 0xd3000000
put32 scratch 0x60000 0x00000004
put32 scratch 0x60004 ${SD_TYPE:-0x00000080}
put32 scratch 0x60008 0x00003f00
put32 scratch 0x6000c 0x00000000
put32 scratch 0x60010 0x00000000
put32 scratch 0x60014 0x00000000
put32 scratch 0x60018 0x40000000
put32 scratch 0x6001c 0x80000000
