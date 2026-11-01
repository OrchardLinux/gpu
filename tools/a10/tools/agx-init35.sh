#!/bin/busybox sh
# BEFORE_INIT hook: bypass SLC for the command-stream/PDS page to test coherency.
. /run/agx-init33.sh
# Kext AGXGartG3ThruG9 PTE flag method 0xfffffff0060364d0 maps bit 3 as-is.
# Upstream Rogue names it SLC_BYPASS_CTRL. All mapped DMA remains our scratch.
put32 scratch 0x48000 $((((S + 0x60000) & 0xffffffff) | 9))
