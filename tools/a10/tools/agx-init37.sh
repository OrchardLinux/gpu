#!/bin/busybox sh
# BEFORE_INIT hook: map the faulting PDS heap base to an owned HALT-program page.
. /run/agx-init36.sh
# Experiment 36 fault 0x0300000000003229 decodes to VA 0x300000000,
# req8, level2: the PC entry for the PDS heap is absent. P+0x18 set this base.
PDS_PD=$((S + 0x80000)); PDS_PT=$((S + 0x7c000)); PDS_PAGE=$((S + 0x84000))
put32 scratch $((0x40000 + 12 * 4)) $(((PDS_PD >> 12) << 4 | 1))
put32 scratch 0x80000 $(((PDS_PT & 0xffffffff) | 3))
put32 scratch 0x80004 $((PDS_PT >> 32))
put32 scratch 0x7c000 $(((PDS_PAGE & 0xffffffff) | 13)) # valid, read-only, SLC bypass
put32 scratch 0x7c004 $((PDS_PAGE >> 32))
put32 scratch 0x84000 0xd3000000 # provisional Rogue PDS HALT, no USC dispatch
