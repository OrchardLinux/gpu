#!/bin/busybox sh
# BEFORE_INIT: a compute dispatch shaped exactly like the one iPadOS 17.7 submits
# for a one-thread Metal kernel (ios-capture, call_000 CDM stream record 1):
#   CDM record: k0 0x2103, k1 data, k2 code, k3-k5 0 (1x1x1), k8 0x40000000,
#               one more zero word (A10 records are 8 words), then terminate
#               0x80000000.
#   PDS code:   BRA !IF1 +2; HALT; DOUTW; DOUTU (cc=1, end=1); HALT.
#   PDS data:   {USC offset, 0x10 (temps 2), 0x80000000, 0}.
# 58-65 lacked the 8th record word and pointed k1 at data 0x80, not 0x800.
# USC: native applegpu_g9p empty kernel at offset 0x2000 (as 63).
# PDS/USC page: VA 0x300000000 -> scratch+0x84000.
USC_OFF=0x00002000
. /run/agx-init63.sh
# PDS data at 0x800.
put32 scratch 0x84800 ${USC_OFF}
put32 scratch 0x84804 0x00000010
put32 scratch 0x84808 0x80000000
put32 scratch 0x8480c 0
# PDS code at 0x3f00.
put32 scratch 0x87f00 0xc2c00002
put32 scratch 0x87f04 0xd3000000
put32 scratch 0x87f08 0xf0000a01
put32 scratch 0x87f0c 0xfc000002
put32 scratch 0x87f10 0xd3000000
put32 scratch 0x87f14 0
# CDM stream (RGX+0x480 -> scratch+0x60000).
put32 scratch 0x60000 ${K0:-0x00002103}
put32 scratch 0x60004 0x00000800
put32 scratch 0x60008 0x00003f00
put32 scratch 0x6000c 0
put32 scratch 0x60010 0
put32 scratch 0x60014 0
put32 scratch 0x60018 0x40000000
put32 scratch 0x6001c 0
put32 scratch 0x60020 0x80000000
put32 scratch 0x60024 0
