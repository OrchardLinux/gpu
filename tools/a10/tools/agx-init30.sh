#!/bin/busybox sh
# BEFORE_INIT hook: force a full context-0 GPU MMU invalidation after PTE writes.
. /run/agx-init29.sh
# T+0x7dc -> generations at VA 0x142000; X+0x188 -> acknowledged generations.
# Difference in bits >=22 selects PC/PD/PT invalidate command 4 (fw 0x18530).
put32 scratch 0x52000 0x400000
