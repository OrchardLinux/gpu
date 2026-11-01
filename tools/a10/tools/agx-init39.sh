#!/bin/busybox sh
# Historical FAILED hypothesis: pending bit 15 is not our compute-finished IRQ.
. /run/agx-init37.sh
# fw 0x2d0c..0x2d3a handler class 2 consumes pending bit 15, then operates
# on shared X+0x13c compute state. Raw RGX and firmware IRQ masks differ.
# Neither this mask nor 38's mask 8 completes our job. Hook 44 restores mask 4,
# established from the actual compute-finished trace after correcting the stream.
put32 scratch 0x54048 0x200000 # WaitIRQ mask 0x8000 << 6
