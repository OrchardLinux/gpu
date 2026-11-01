#!/bin/busybox sh
# BEFORE_INIT hook: queue's available hardware-unit mask (bit 0).
. /run/agx-init22.sh
put32 scratch 0x2b044 1
