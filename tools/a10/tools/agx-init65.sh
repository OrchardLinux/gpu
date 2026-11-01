#!/bin/busybox sh
# BEFORE_INIT: control for 64. Same native PDS encoding, USC offset 0x4000 ->
# unmapped 0x300004000: a USC fetch fault there proves DOUTU issues the task
# and that the USC code base is 0x300000000.
DOUTU_WORD=0xf4000002
SRC0_HI=0x00000010
USC_OFF=0x00004000
. /run/agx-init62.sh
