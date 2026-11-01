#!/bin/busybox sh
# BEFORE_INIT hook: init13 plus a valid context-base array for fw 0x18352.
# E0PA=0x201d00000 ESIZE=0x5000 BEFORE_INIT=/run/agx-init14.sh sh /run/agx-init12.sh
# GPU root is an empty, zeroed page. NO GPU jobs or mappings are supplied.
. /run/agx-init13.sh
# T = init+0x1c, VA 0x104000; T+0x7e0 points to 256 physical root addresses.
# Table is in mapped scratch VA 0x126000; context 0 root at scratch+0x40000.
put32 scratch $((0x4000 + 0x7e0)) $((VA + 0x26000))
put32 scratch 0x26000 $(((S + 0x40000) & 0xffffffff))
put32 scratch 0x26004 $(((S + 0x40000) >> 32))
