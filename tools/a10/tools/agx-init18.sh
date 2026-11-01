#!/bin/busybox sh
# BEFORE_INIT hook: compute probe + MMU context-generation table for fw 0x18530.
. /run/agx-init17.sh
put32 scratch $((0x4000 + 0x7dc)) 0x142000
