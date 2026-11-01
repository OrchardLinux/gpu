#!/bin/busybox sh
# Historical FAILED hypothesis: mask 8 is not the compute-finished wait mask.
. /run/agx-init37.sh
# Experiment 37 had no MMU fault, but its initial status 8 was not completion.
# Later trace 42 established status 4; hook 44 restores the original mask.
# fw 0xa3fa waits on firmware [0x8e550+0x140], not raw upstream RGX bit 2.
put32 scratch 0x54048 0x200 # WaitIRQ mask 8 << 6
