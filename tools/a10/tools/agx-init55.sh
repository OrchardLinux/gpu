#!/bin/busybox sh
# BEFORE_INIT: execution test for PDS. Put a two-way branch at the end of the
# mapped 16 KiB PDS code page; both paths target 0x300004000, the next page.
# If the PDS executes a branch instruction it must fetch the unmapped page and
# raise an MMU fault. If the task only fetches the first code page, or stalls
# before execution, no fault appears. This separates fetch from execution.
. /run/agx-init46.sh
# PDS code page is GPU VA 0x300000000, 16 KiB (scratch + 0x84000).
# Code offset 0x3f00 -> scratch 0x87f00.
put32 scratch 0x87f00 0xc2c00040 # BRA !IF1, KEEP, +0x40 instructions
put32 scratch 0x87f04 0xc240003f # BRA  IF1, KEEP, +0x3f instructions
put32 scratch 0x87f08 0xd3000000 # HALT (only if neither predicate fires)
# One 16-byte constant block at PDS data offset 0x800.
put32 scratch 0x84800 0
put32 scratch 0x84804 0
put32 scratch 0x84808 0
put32 scratch 0x8480c 0
# PDS kernel: code 0x3f00, data 0x800, one data chunk, no fence, no temp,
# all clusters, 1x1x1 groups, max 8 instances.
put32 scratch 0x60000 0x00000004
put32 scratch 0x60004 0x00000080
put32 scratch 0x60008 0x00003f00
put32 scratch 0x6000c 0x00000000
put32 scratch 0x60010 0x00000000
put32 scratch 0x60014 0x00000000
put32 scratch 0x60018 0x40000000
put32 scratch 0x6001c 0x80000000
