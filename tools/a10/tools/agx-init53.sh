#!/bin/busybox sh
# PDS-only store probe: observable write without USC execution/completion claims.
. /run/agx-init46.sh
# Fresh PDS 16 KiB page at GPU heap +0x4000; old programs may be cached.
PDS2=$((S + 0xa0000)); OUT=$((S + 0x98000))
put32 scratch 0x7c008 $(((PDS2 & 0xffffffff) | 13))
put32 scratch 0x7c00c $((PDS2 >> 32))
# GPU VA 0x204000 -> exclusively owned writable/SLC-bypass output page.
put32 scratch 0x48008 $(((OUT & 0xffffffff) | 9))
put32 scratch 0x4800c $((OUT >> 32))
put32 scratch 0x98000 0xabadbeef
# Generic Rogue instructions, independently checked with Mesa C pack/disasm:
# coefficient task -> HALT; regular task -> LIMM temp0, ST const64[0], WDF,
# DOUTC, HALT. A marker write is meaningful even if completion still stalls.
put32 scratch 0xa0000 0xc2c00002
put32 scratch 0xa0004 0xd3000000
put32 scratch 0xa0008 0xd1804d5c # LIMM temp32[0] = 0x1357
put32 scratch 0xa000c 0xd0800000 # ST descriptor const64[0]
put32 scratch 0xa0010 0xd1000000 # WDF
put32 scratch 0xa0014 0xf0000005
put32 scratch 0xa0018 0xd3000000
# Descriptor: destination VA 0x204000, count=1 dword, temp source 0,
# write-through MCU/SLC policy. Source: pvr_pds_generate_common_ld_st, ST branch.
put32 scratch 0xa0800 0x204000
put32 scratch 0xa0804 0x100
put32 scratch 0xa0808 0
put32 scratch 0xa080c 0
put32 scratch 0x60000 0x107 # fence, ANY, data chunk1, temp chunk1 (4 dwords)
put32 scratch 0x60004 0x4804 # data offset + PDS dependency
put32 scratch 0x60008 0x4000 # code offset
put32 scratch 0x6000c 0
put32 scratch 0x60010 0
put32 scratch 0x60014 0
put32 scratch 0x60018 0x40000000
put32 scratch 0x6001c 0x80000000
