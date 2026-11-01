#!/bin/busybox sh
# BEFORE_INIT hook: firmware trace ring, required even with debug flags disabled.
. /run/agx-init26.sh
put16 mem $((DESC + 0x1c)) 32
put32 scratch 0xf4 0x158000 # trace control, consumer +0 / producer +0x20
put32 scratch 0xf8 0x154000 # 256 x 60-byte records (4 pages)
