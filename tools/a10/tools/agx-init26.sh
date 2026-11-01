#!/bin/busybox sh
# BEFORE_INIT hook: minimal CDM terminate stream, Start/Wait/Finalize/End.
# RAM RGX by default; real GPU submission requires explicit separate authorization
# in the runner. No USC shader: PDS program is a single HALT instruction.
. /run/agx-init25.sh
# GPU context 0: Rogue PC(u32)->PD(u64)->PT(u64), one 16 KiB page.
# GPU VA 0x200000 maps only scratch+0x60000..+0x63fff.
# These PTEs are a hypothesis from upstream Rogue + kext format, not yet validated.
PD=$((S + 0x44000)); PT=$((S + 0x48000)); DATA=$((S + 0x60000))
put32 scratch 0x40000 $(((PD >> 12) << 4 | 1))
put32 scratch $((0x44000 + 8)) $(((PT & 0xffffffff) | 3)) # PD index 1, 16 KiB leaf
put32 scratch $((0x44000 + 12)) $((PT >> 32))
put32 scratch 0x48000 $(((DATA & 0xffffffff) | 1))
put32 scratch 0x48004 $((DATA >> 32))
put32 scratch 0x60000 0x80000000 # Rogue CDM STREAM_TERMINATE (block type 2)
put32 scratch 0x61000 0xd3000000 # Rogue PDS HALT; no USC task
# Historical guesses for P[0..0x27], corrected to kext constants by hook 31.
# These fields are NOT the scratch physical-memory range/context root.
put32 scratch 0x2000 $((S & 0xffffffff))
put32 scratch 0x2004 $((S >> 32))
put32 scratch 0x2008 0x400000
put32 scratch 0x2018 $(((S + 0x40000) & 0xffffffff))
put32 scratch 0x201c $(((S + 0x40000) >> 32))
# Historical CDM argument interpretation: +0x00 actually targets RGX+0x498
# (context/storage); the real stream is +0x10 -> RGX+0x480, fixed by hook 42.
# +0x08/+0x0c are terminate PDS code/data addresses.
put32 scratch 0x5b000 0x200000
put32 scratch 0x5b008 0x201000
put32 scratch 0x5b00c 0x201010
# StartCompute is 0x48 bytes: two register-state pointers, unit-state array,
# context ID, context-save state, guard/deadline pointers.
dd if=/dev/zero of="$D/scratch" bs=1 seek=$((0x54000)) count=$((0x80)) conv=notrunc 2>/dev/null
put32 scratch 0x54000 11
put32 scratch 0x54004 0x14c000
put32 scratch 0x54008 0x14b000
put32 scratch 0x5400c 0x146000
put32 scratch 0x5402c 0x143000
put32 scratch 0x54038 0x146100
put32 scratch 0x54044 0x146108
put32 scratch 0x56108 1
put32 scratch 0x5600c 0
# WaitIRQ mask 4 is provisional; only a real GPU run can validate it.
put32 scratch 0x54048 0x100
# FinalizeCompute 0x30 bytes, then End 4 bytes.
put32 scratch 0x5404c 12
put32 scratch 0x54050 0x146000
put32 scratch 0x54068 0x145000
put32 scratch 0x5406c 1
put32 scratch 0x54074 0x146100
put32 scratch 0x5407c 2
put32 scratch 0x2f1ec 0x80
