#!/bin/busybox sh
# BEFORE_INIT hook: fault-inject register 0x480, independently of 0x498.
. /run/agx-init39.sh
# Experiment 40: putting unmapped VA in 0x498 caused no fault.
# Now leave 0x498 valid and put the same unmapped VA in 0x480.
put32 scratch 0x5b010 0x400000
