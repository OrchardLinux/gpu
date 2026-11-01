#!/bin/busybox sh
# BEFORE_INIT hook: PDS coefficient-completion task, no USC shader.
. /run/agx-init47.sh
# Mesa pvr_pds_generate_doutc: DOUTC src0=const0/src1=const0, then HALT.
# Provide one 16-byte constant block; all constants are zero in the owned page.
put32 scratch 0x84000 0xf0000005
put32 scratch 0x84004 0xd3000000
put32 scratch 0x60000 6 # data_size 1 x 16 bytes, target ANY
# CDM global counts are minus-one encoded, just like local dimensions.
put32 scratch 0x6000c 0
put32 scratch 0x60010 0
put32 scratch 0x60014 0
