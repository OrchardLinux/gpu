#!/bin/busybox sh
# BEFORE_INIT hook: use the actual kext's fixed GPU address-window constants.
. /run/agx-init30.sh
# Kext 0xfffffff006012bd0..0x6012bec initializes P[0..0x27].
# These are NOT our scratch physical-memory range or the context-0 root.
# Context roots remain separately supplied through T+0x7e0.
put32 scratch 0x2000 0
put32 scratch 0x2004 6
put32 scratch 0x2008 0xffc00000
put32 scratch 0x200c 0
put32 scratch 0x2010 0
put32 scratch 0x2014 3
put32 scratch 0x2018 0
put32 scratch 0x201c 3
put32 scratch 0x2020 0xffff8000
put32 scratch 0x2024 1
