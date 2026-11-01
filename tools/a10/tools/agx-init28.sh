#!/bin/busybox sh
# BEFORE_INIT hook: enable firmware SKU tracing into a separate, large buffer.
. /run/agx-init27.sh
put16 mem $((DESC + 0x1c)) 64
put32 scratch 0xec 0x165000 # trace control, 512 entries
put32 scratch 0xf0 0x160000 # 512 x 36-byte records (5 pages)
put32 scratch 0x5000 3     # U+0 -> shared debug flags +0x4c
