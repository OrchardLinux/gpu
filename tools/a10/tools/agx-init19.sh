#!/bin/busybox sh
# BEFORE_INIT hook: request one-time engine scheduler initialization.
. /run/agx-init18.sh
# V = init+0x9c; V+0x45b4 != 0 takes fw 0x1b688 -> 0xd980.
# Without this, engine callbacks remain NULL and first command branches to 0.
put32 scratch $((0x8000 + 0x45b4)) 1
