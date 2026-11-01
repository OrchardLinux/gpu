#!/bin/busybox sh
# BEFORE_INIT hook: one actual PDS kernel task (HALT only), then stream terminate.
# This dispatches NO USC shader and writes no shader result.
. /run/agx-init46.sh
# Rogue cdm.xml KERNEL0/1/2/3/4/5/8, one group and one local work item.
# PDS code/data are offsets in the configured 0x300000000 heap, mapped by 37.
put32 scratch 0x60000 2          # USC target ANY, no USC/temp/data allocation
put32 scratch 0x60004 0x100      # data offset, no constants actually loaded
put32 scratch 0x60008 1          # code offset 0, one workgroup per task
put32 scratch 0x6000c 1          # groups X
put32 scratch 0x60010 1          # groups Y
put32 scratch 0x60014 1          # groups Z
put32 scratch 0x60018 0x08000000 # max instances 1, local size 1x1x1 (minus-one)
put32 scratch 0x6001c 0x80000000 # terminate
