#!/bin/busybox sh
# BEFORE_INIT control for experiment 55: same two-way branch, but target a
# MAPPED HALT at 0x3f0c. No fault is expected. Completion distinguishes a PDS
# task that runs and retires from one that executes but never completes.
. /run/agx-init46.sh
put32 scratch 0x87f00 0xc2c00003 # BRA !IF1, KEEP, +3 instructions
put32 scratch 0x87f04 0xc2400002 # BRA  IF1, KEEP, +2 instructions
put32 scratch 0x87f0c 0xd3000000 # HALT
put32 scratch 0x84800 0
put32 scratch 0x84804 0
put32 scratch 0x84808 0
put32 scratch 0x8480c 0
put32 scratch 0x60000 0x00000004
put32 scratch 0x60004 0x00000080
put32 scratch 0x60008 0x00003f00
put32 scratch 0x6000c 0x00000000
put32 scratch 0x60010 0x00000000
put32 scratch 0x60014 0x00000000
put32 scratch 0x60018 0x40000000
put32 scratch 0x6001c 0x80000000
