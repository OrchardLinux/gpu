#!/bin/busybox sh
# BEFORE_INIT: first shader-written result. Reproduces the two CDM records
# iPadOS 17.7 submits per one-thread Metal dispatch (ios-capture7):
#   record 0: DMA-only PDS task (DOUTD x2) loading the buffer binding from an
#             argument-table entry {buffer GPU VA, unused, 0x10001} into the
#             USC common store (k1 usc_common_shared);
#   record 1: the kernel, as in 66, running the native applegpu_g9p
#             store_marker (`out[0] = 0x1357`).
# Output: GPU VA 0x204000 -> owned writable page at scratch+0x98000 (as 53),
# initialized to 0xabadbeef. Success: it reads 0x1357 afterwards.
# PDS/USC page: VA 0x300000000 -> scratch+0x84000 (16 KiB).
. /run/agx-init46.sh
OUT=$((S + 0x98000))
put32 scratch 0x48008 $(((OUT & 0xffffffff) | 9))
put32 scratch 0x4800c $((OUT >> 32))
put32 scratch 0x98000 0xabadbeef
put32 scratch 0x98004 0xabadbeef
# Argument table entry at 0x1000 (VA 0x300001000).
put32 scratch 0x85000 0x00204000
put32 scratch 0x85004 0
put32 scratch 0x85008 0
put32 scratch 0x8500c 0
put32 scratch 0x85010 0x00010001
put32 scratch 0x85014 0
# Record 0 PDS data at 0x900: two DOUTD sources and their control words.
put32 scratch 0x84900 0x00001000
put32 scratch 0x84904 0x00000003
put32 scratch 0x84908 0x00001010
put32 scratch 0x8490c 0x00000003
put32 scratch 0x84910 0x10000002
put32 scratch 0x84914 0
put32 scratch 0x84918 0x90004001
put32 scratch 0x8491c 0
# Record 0 PDS code at 0x3e00: DOUTD; DOUTD (end); HALT.
put32 scratch 0x87e00 0xf0001000
put32 scratch 0x87e04 0xf4001808
put32 scratch 0x87e08 0xd3000000
put32 scratch 0x87e0c 0
# Kernel PDS data at 0x800: USC offset 0x2000, temps 2, DOUTW value.
put32 scratch 0x84800 0x00002000
put32 scratch 0x84804 0x00000010
put32 scratch 0x84808 0x80000000
put32 scratch 0x8480c 0
# Kernel PDS code at 0x3f00.
put32 scratch 0x87f00 0xc2c00002
put32 scratch 0x87f04 0xd3000000
put32 scratch 0x87f08 0xf0000a01
put32 scratch 0x87f0c 0xfc000002
put32 scratch 0x87f10 0xd3000000
put32 scratch 0x87f14 0
# USC at 0x2000: store_marker as compiled by metal-tt -arch applegpu_g9p and
# byte-identical to what iPadOS loaded.
o=0x86000
for w in 0x81891181 0xacb74100 0x030201c8 0x01200101 0x219846d1 0x012f0300 \
         0x0154212a 0x09000038 0x0000010c 0x01802312 0x21c88000 0x01840302 \
         0x010046d2 0x0000010e 0xc000c000 0xc000c000 0x00008000 0 0 0; do
    put32 scratch $o $w
    o=$((o + 4))
done
# CDM stream: record 0, record 1, terminate.
o=0x60000
for w in 0x00000004 0x00000902 0x00003e00 0 0 0 0x40000001 0 \
         0x00002103 0x00000800 0x00003f00 0 0 0 0x40000000 0 \
         0x80000000 0; do
    put32 scratch $o $w
    o=$((o + 4))
done
