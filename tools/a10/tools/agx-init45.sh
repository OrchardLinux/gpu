#!/bin/busybox sh
# BEFORE_INIT DIAGNOSTIC: catch the finalize-path write fault at GPU VA 0.
. /run/agx-init44.sh
# 44 reaches real compute IRQ + FinalizeCompute, then faults 0xff251:
# requestor 9, write, PD-level fault at VA 0. Map ONLY an owned 16 KiB
# scratch page there to inspect what it writes. This is NOT a production fix.
NULL_PT=$((S + 0x90000)); NULL_PAGE=$((S + 0x94000))
put32 scratch 0x44000 $(((NULL_PT & 0xffffffff) | 3))
put32 scratch 0x44004 $((NULL_PT >> 32))
put32 scratch 0x90000 $(((NULL_PAGE & 0xffffffff) | 9))
put32 scratch 0x90004 $((NULL_PAGE >> 32))
