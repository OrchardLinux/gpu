#!/bin/busybox sh
# BEFORE_INIT hook: test Apple's 3-bit CDM block encoding, not IMG's 2-bit one.
. /run/agx-init33.sh
# Mesa Asahi CDM: type 2 << 29 = terminate; 0x80000000 is type 4 (return).
# The previous word may have returned to VA 0, explaining requestor-4 fault 0x119.
# This encoding is a hypothesis until the hardware completion test passes.
put32 scratch 0x60000 0x40000000
