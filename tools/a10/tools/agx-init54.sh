#!/bin/busybox sh
# Negative control: unguarded PDS ST to deliberately UNMAPPED GPU VA 0x400000.
. /run/agx-init53.sh
# Fresh code/data offsets 0x5000/0x5800 in the newly mapped PDS page.
# If generic Rogue ST executes, expect a WRITE MMU fault at 0x400000.
# No branch/predicate guard, no DOUTC/USC instruction, no permitted target write.
put32 scratch 0xa1000 0xd1804d5c
put32 scratch 0xa1004 0xd0800000
put32 scratch 0xa1008 0xd1000000
put32 scratch 0xa100c 0xd3000000
put32 scratch 0xa1800 0x400000
put32 scratch 0xa1804 0x100
put32 scratch 0xa1808 0
put32 scratch 0xa180c 0
put32 scratch 0x60004 0x5804
put32 scratch 0x60008 0x5000
