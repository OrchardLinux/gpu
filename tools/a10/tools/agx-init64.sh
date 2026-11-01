#!/bin/busybox sh
# BEFORE_INIT: 63 (native G9P empty kernel at USC offset 0x2000) with the PDS
# program iOS itself uses for that kernel, captured from GPU memory under
# iPadOS 17.7 (ios-capture/): DOUTU 0xf4000002 (end=1, cc=0) + HALT, data
# src0 = {offset, 0x10} -> temps field 2 (bit 36). 58-63 never had the end bit.
DOUTU_WORD=0xf4000002
SRC0_HI=0x00000010
. /run/agx-init63.sh
