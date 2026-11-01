#!/bin/busybox sh
# BEFORE_INIT hook: enable one scheduling unit per TA/3D/compute engine.
. /run/agx-init21.sh
# fw 0x17f54..0x17f78 copies these masks to shared+0x774/+0x778/+0x77c.
# Zero masks disable all microsequence execution (0x99d0).
put32 scratch $((0x2000 + 0x16c0)) 1
put32 scratch $((0x2000 + 0x16c4)) 1
put32 scratch $((0x2000 + 0x16c8)) 1
