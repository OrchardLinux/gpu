#!/bin/busybox sh
# BEFORE_INIT hook: host completion stamp and firmware->host event ring.
. /run/agx-init24.sh
put32 scratch 0x2f26c 0x145004 # host notification stamp address
put32 scratch 0x2f274 1        # stamp value, also contains scheduling tag
put32 scratch 0xdc 0x147000   # event-ring control (consumer +0, producer +0x20)
put32 scratch 0xe0 0x148000   # 256 x 36-byte event entries, 3 mapped pages
