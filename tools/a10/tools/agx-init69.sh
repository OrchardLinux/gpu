#!/bin/busybox sh
# BEFORE_INIT: control for 68. The argument table binds the buffer at GPU VA
# 0x204010 instead of 0x204000; the marker must move to +0x10 of the output
# page, proving the store goes through the DMA-loaded binding.
. /run/agx-init68.sh
put32 scratch 0x98010 0xabadbeef
put32 scratch 0x85000 0x00204010
