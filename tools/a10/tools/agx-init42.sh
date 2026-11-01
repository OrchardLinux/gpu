#!/bin/busybox sh
# BEFORE_INIT hook: correct the CDM address-register interpretation.
. /run/agx-init39.sh
# Hardware fault injection: 0x498=unmapped does NOT fault (experiment 40),
# 0x480=unmapped 0x400000 DOES fault at precisely 0x400000 (experiment 41).
# Test actual stream at 0x480, owned zeroed context/storage at 0x498.
put32 scratch 0x5b010 0x200000
put32 scratch 0x5b000 0x202000
