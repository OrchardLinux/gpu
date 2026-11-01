#!/bin/busybox sh
# BEFORE_INIT hook: compute probe + 128 x 44-byte firmware scheduling entries.
. /run/agx-init16.sh
# A second noncacheable mapping: VA 0x140000 -> scratch+0x50000, 16 pages.
put32 mem $((DESC + 0x10)) 0x140000
put32 mem $((DESC + 0x14)) $(((S + 0x50000) >> 12))
put32 mem $((DESC + 0x18)) 0
put16 mem $((DESC + 0x1c)) 16
put16 mem $((DESC + 0x1e)) 0
put32 mem $((INIT + 0x94)) 2
put32 scratch 0x2b00c 0x140000
