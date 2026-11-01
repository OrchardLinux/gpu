#!/bin/busybox sh
# BEFORE_INIT hook: fault-inject ONLY the presumed stream-base register 0x498.
. /run/agx-init39.sh
# VA 0x400000 has no PD entry. A real fetch via 0x498 should now fault there.
# This intentionally unmapped address cannot access memory outside our tables.
put32 scratch 0x5b000 0x400000
