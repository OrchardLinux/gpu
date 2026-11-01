#!/bin/busybox sh
# BEFORE_INIT hook: use the shared compute-unit state monitored by recovery.
# The microsequence's unit array must be X+0x13c's target, not a private page.
. /run/agx-init28.sh
put32 scratch 0x5400c 0x11e000 # StartCompute unit states
put32 scratch 0x54050 0x11e000 # FinalizeCompute unit states
