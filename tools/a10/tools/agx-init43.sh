#!/bin/busybox sh
# BEFORE_INIT hook: retest Apple-style CDM terminate with the real stream register.
. /run/agx-init42.sh
# Previous encoding comparison (34) never put the stream at RGX+0x480.
# 42 with 0x80000000 sets context-store status 1, but no completion stamp.
put32 scratch 0x60000 0x40000000
