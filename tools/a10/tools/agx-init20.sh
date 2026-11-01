#!/bin/busybox sh
# BEFORE_INIT hook: mapped compute context and microsequence; still RAM RGX.
. /run/agx-init19.sh
put32 scratch 0x2f014 0x143000 # compute context, >= 0x84 bytes
put32 scratch 0x2f1e8 0x144000 # microsequence pointer
put32 scratch 0x2f1ec 4        # microsequence byte size
# These are scalar scheduler/count fields, NOT pointers (corrects section 13).
put32 scratch 0x1ec 0
put32 scratch 0x1fc 0
