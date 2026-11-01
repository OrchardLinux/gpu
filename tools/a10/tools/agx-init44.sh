#!/bin/busybox sh
# BEFORE_INIT hook: corrected real stream address with the original compute IRQ.
. /run/agx-init42.sh
# Experiment 42 trace 0x102 contains r2=3, r3=0x80000000, stack0=4,
# stack1=0: the firmware pending status is 4. The mask-8/0x8000 detours
# were wrong. Retest mask 4 now that actual RGX+0x480 points at our stream.
put32 scratch 0x54048 0x100
