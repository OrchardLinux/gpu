#!/bin/busybox sh
# BEFORE_INIT hook: end-only microsequence (opcode 2, not opcode 0/wait IRQ).
# This tests CPU-side queue completion, not GPU execution.
. /run/agx-init20.sh
put32 scratch 0x54000 2
