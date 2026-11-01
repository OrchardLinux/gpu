# Provenance of the A10 GPU driver's values

Where every hardware/firmware-facing value in the Apple path of the GPU
driver (`drivers/gpu/drm/imagination/pvr_apple*.c`) and in the job
construction of the test tools comes from. Written 2026-10-31 by a
cross-reading audit of the code against the docs in this directory, the
firmware/kext/Metal-driver decompiles (cited by function or address only;
decompiled code is never copied) and the iPadOS captures. Use it before
reusing a value for another A-chip GPU: only SOURCED values transfer with
confidence; DERIVED and UNKNOWN values are hypotheses to re-check.

Classes: SOURCED-decompile, SOURCED-capture, SOURCED-experiment, DERIVED,
UNKNOWN; tags for placeholders, debug-only settings and iOS mismatches.
Line numbers refer to the code as of the audit (kernel patch at the
"acknowledge firmware events" commit, `pvr-compute-test.c` after the
`g9p-cdm.h` rewrite).

## Status of the ranked risks (updated after the audit)

- **Risk 1, power-state struct over the geometry queue: fixed** (2026-10-31).
  X+0x301 now points at its own pages (heap 0x69000, fw 0x159000);
  `tools/layout-test` lists it as an intended deviation from baseline 46.
- **Risk 2, fragment unit-state pointer: fixed** (2026-10-31). Start3D w4
  and Finalize3D w7 use the X+0x138 page + 8, as fw 0x54ec does for engine
  1. Verified: full test set and 300 renders interleaved with 300 compute
  jobs pass.
- **`usc_store_marker`:** now written from the decoded encodings (same
  words as the compiler's output; see COMPUTE.md "Job construction").
- All other risks below are open.


Audit date 2026-10-31. Read-only audit: no repository file was changed and the device was not touched.

## Scope and revisions audited

| Code | Revision |
|---|---|
| `gpu-repo2/drivers/gpu/drm/imagination/pvr_apple.c` (2083 lines), `pvr_apple_layout.c` (742), `pvr_apple_layout.h` (64), `pvr_apple.h` (131), `pvr_apple_queue.c` (138) | commit `e8ce2e1` "drm/imagination: Support the Apple A10 (T8010) GPU", committer date 2026-10-31 03:23 (amended during this audit; line numbers below are for this state) |
| `examples/gpu-001/tools/pvr-compute-test.c` (500 lines) plus `tools/g9p-cdm.h` (237 lines, which the test now includes) | working tree 2026-10-31 ~03:25 (rewritten during this audit; line numbers are for this state) |
| `examples/gpu-001/tools/pvr-render-test.c` (439 lines) | working tree |

Paths: `S` = scratchpad root, `G` = `examples/gpu-001` (in the orchard checkout). In the tables, `layout.c`, `apple.c`, `apple.h`, `layout.h`, `compute-test.c`, `cdm.h` and `render-test.c` are the files above. Docs are cited as `COMPUTE.md:line`, `FENDER.md §n`, and so on. Experiment hooks are `G/tools/agx-initNN.sh`. Hardware logs are under `G/out/resume/`.

Decompile sources: `fw` = GFX firmware (`S/ghidra/fw-all.c`, Thumb, load base 0, cited by firmware address). `kext17` = iOS 17.7.11 AGXG9P kext (`S/ghidra/agxg9p.c`, kernel VA). `kext10` = unstripped iOS 10 T8010 AGX kext (`S/unstripped/agx10-all.c`, by symbol). `Metal` = AGXMetalA10 (`S/agxm/pds.c`, `syms.txt`). No decompiled code is reproduced here.

### Classes

| Class | Meaning |
|---|---|
| **SOURCED-decompile** | The value itself, not just the field, is read from fw/kext/Metal code. |
| **SOURCED-capture** | Copied from, or byte-identical to, an iPadOS capture. |
| **SOURCED-experiment** | Our choice; the field's role comes from decompile or docs, and the value was validated by a documented device run. |
| **DERIVED** | Reasoned from the above but not observed directly, for example by analogy between engines or from a Rogue/Mesa name. |
| **UNKNOWN** | No A10 source found. |

Extra tags:

| Tag | Meaning |
|---|---|
| `[PLACEHOLDER]` | Stands in for something real. |
| `[DEBUG]` | Debug or bring-up only. |
| `[CONFLICT]` | Collides with another structure. |
| `[MISMATCH-iOS]` | The iOS 17 kext builds this field differently. |
| `[STALE-COMMENT]` | The meaning in the code comment is contradicted by a later doc or decompile. |

Where a row has both decompile and experiment support, the class names the stronger source for the *value*. The source column gives the other.

---

## 1. Tables

### 1.1 Firmware transport, boot, power (`apple.c`, `layout.h`)

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| apple.c:50 | RTKit EP, init | 0x20 | AGX init endpoint | SOURCED-decompile | fw init handler 0x179e0 receives on EP 0x20 (fw 0x179f4) (FENDER.md §8.1). EPMAP 0,1,0x20,0x21 observed live (README.md "Results on J71b"). |
| apple.c:51 | RTKit EP, doorbell | 0x21 | doorbell | SOURCED-experiment | crashlog8: the EP 0x21 handler drains the mapping ring (fw 0x181ee); 0x83 sent on EP 0x20 is ignored (FENDER.md §14.1, README.md:176) |
| apple.c:52 | init message | 0x81<<48 \| PA | init page PA | SOURCED-decompile | kext17 0x…602cb48 (FENDER.md §7.1). fw 0x17a0c checks type 0x81/0xc1, PA[43:0] unshifted (§8.1). |
| apple.c:53 | kick message | 0x83<<48 (no ring bits) | "scan rings" | DERIVED | kext17 `kickFirmware` 0x…6022640 sends `0x83<<48 \| (ring&7)<<2 [\|2]` (FENDER.md §6.4/§7.1). The driver omits the ring bits. Works for all rings (uapi21/22 logs), but the doorbell event table at fw 0x2e7e8 (bits 0x1/0x2/0x4 → 0x1ff85(0/1/2)) is not mapped to payload bits. |
| apple.c:56-58 | Fender +0x1000 | request 0x10\|state, ack `&0x1f == state` | core power state | SOURCED-decompile | fw 0x16d40 (0x16df2 builds target\|0x10; 0x16e86 polls &0x1f) (FENDER.md §18.1). Hardware: `fender-request11.log`, `core-identity.log`. |
| apple.c:59, 238-247 | Fender window 0x200c..0x2020 (stride 4) | {win lo, win hi, 0, 0, 0x100000, 0} | firmware window | SOURCED-decompile (fields) | kext17 V2GFX `_mapFirmware` 0x…4155c (FENDER.md §4.1-4.2). The length 1 MiB is our choice (README.md "1 MB uncached buffer"). iOS maps the 0x8f000 runtime size (§4.3). |
| apple.c:60-61 | Fender +0x2048 bit 0 | 1 | IOP run | SOURCED-decompile | kext17 V2GFX run override 0x…415fc (FENDER.md §4.1) |
| apple.c:64-65 | A7IOP +0x08.. (stride 8), +0x38 | same fields; enable 1 | IOP window copy | SOURCED-decompile | kext17 V2 `_mapFirmware` 0x…41028 (FENDER.md §4.2) |
| apple.c:68, 2018 | U+0x14 == 1 | ready | firmware accepted init | SOURCED-decompile | fw 0x1bac6 clears and 0x1bb3c sets U[0x14] (FENDER.md §11.1-11.2). Hardware: agx-init4 "Ready reached" (README.md:174). |
| apple.c:298 | DMA mask | 40 bits | firmware addresses PA | DERIVED | the fw PA field is 44 bits (fw 0x17a24). 40 = Rogue bus width. Not tested above 2^40. |
| apple.c:305 | window alignment | 16 KiB | — | DERIVED | FENDER.md §4.3 "alignment requirement is inferred" |
| apple.c:308, 198 | RTKit buffers | carved in window [0x8f000, 0x98000) | — | SOURCED-experiment | driver1.log (RTKit v12 boot in-driver) |
| apple.c:359-367 | power sequence | state 0 (if not 0), then 1 | reset a core left on | SOURCED-experiment | hook 32 (fw 0x16df8 uses request 0x10 for state 0). COMPUTE.md:196. |
| layout.h:9 | PVR_APPLE_WINDOW_SIZE | 0x100000 | IOP window | SOURCED-experiment | as above |
| layout.h:10 | PVR_APPLE_FW_RUNTIME | 0x8f000 | image + runtime | SOURCED-decompile | kext17 getRuntimeBinSize 0x…4250. Image 0x5b320 (FENDER.md §3, §4.3). |
| layout.h:11 | PVR_APPLE_HEAP_SIZE | 0x400000 | firmware heap | SOURCED-experiment | 4 MiB scratch of agx-init12 (I/O RAM ends exactly at 0x400000) |

### 1.2 Init page and memory descriptors (`layout.c`)

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:33 | WIN_INIT | 0x98000 | init page in window | SOURCED-experiment | FENDER.md §9.4 (I = W+0x98000); golden image of baseline 46 (DRIVER.md:38-43) |
| layout.c:34 | WIN_DESC | 0x9c000 | mem-desc page | SOURCED-experiment | §9.4. fw maps a constant 16 KiB at init+0x8c (fw 0x17b30/0x17b3a, §8.2). |
| layout.c:359 | init+0x08/+0x0c | heap_pa+0x38000, page left zero | "empty sequence" | SOURCED-decompile (field) `[PLACEHOLDER]` | fw 0x57e6 maps it, interpreter fw 0x5828, type 0 = end (FENDER.md §17.1-17.2). An empty program was validated by hook 13 (`init13-real-kick.log`). iOS fills it: kext17 0x…6021d10 emits RGX+0xe140/+0xe148 (MMU context select/base) and RGX+0xe160 (time) (§19.5). Not supplied here: e160 is never written. |
| layout.c:360 | init+0x18 | 0x100000 (X) | main context | SOURCED-decompile | → fw global 0x8e54c (FENDER.md §8.3, §9.3); hook 12 |
| layout.c:361 | init+0x1c | 0x104000 (T) | MMU context table | SOURCED-decompile | → 0x8e4c4, ≥0xe1c bytes (§10.2). Fields T+0x7dc/0x7e0/0x7e4/0x808/0x988 per decompile. |
| layout.c:362 | init+0x8c/+0x90 | win_pa+0x9c000 | mem-desc PA | SOURCED-decompile | fw 0x17b30 (§8.2) |
| layout.c:363 | init+0x94 | 2 | descriptor count | SOURCED-decompile | loop fw 0x17b74 (§8.3); hook 17 |
| layout.c:364 | init+0x98 | 0x105000 (U) | debug/ready flags | SOURCED-decompile | → 0x8e4f8; fw uses only +0x14 and +0x18. U[0] is read via the init copy (hook 28). |
| layout.c:365 | init+0x9c | 0x108000 (V) | mapping-update ring owner | SOURCED-decompile | → 0x8e800, ≥0x65c0 bytes (§10.2). Fields +0x455c/+0x4560/+0x45b4 (§14.1, hook 19). |
| layout.c:366 | init+0xa0 | 0x110000 | "power path page" | SOURCED-decompile (pointer); meaning DERIVED | → 0x8e4f4. fw 0x1b2a2 reads and writes +0x1b8/+0x1bc in the power-up path (FENDER.md §11.2). The decompile touches only +0xe8..+0x1e8 (fits the page). "Power path" is named after the code that uses it. |
| layout.c:151-160, 368 | desc0 | {0x100000, heap_pa>>12, 0, 56 pages, flags 0} | heap at fw VA 0x100000 | SOURCED-experiment | fw 0x18084 accepts only VAs with an existing L3 table, i.e. 0x100000-0x1fffff (FENDER.md §10.1). flags 0 → attr 0x41b (inner non-cacheable), required for runtime updates (§19.3, hook 15, `init15-nc-control.log`). |
| layout.c:28-30, 369 | desc1 | {0x140000, heap_pa+0x50000, 64 pages} | second mapping | SOURCED-experiment | hooks 17/27/28 (16 → 32 → 64 pages) |

### 1.3 Main context X (heap 0x0, fw VA 0x100000; `layout.c`)

| file:line | field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:179 | X+0x0 | 0x102000 (P) | device context | SOURCED-decompile | `[[0x8e54c]]` (FENDER.md §9.3, §11.1) |
| layout.c:180 | X+0x4 | 0x106000 (Q) | flush scratch | SOURCED-decompile | fw 0x1bb0a/0x1bb18 (§11.1) |
| layout.c:181 | X+0x8 | 0x107000 (Z) | — | SOURCED-decompile | fw 0x1c626: Z[0]==0 → fallback path (§11.2) |
| layout.c:184-188 | X+0xc/+0x10/+0x14 + 0x10·i, i<13 | 0x111000+0x10i (+4, +8) | consumer / cache / producer index | SOURCED-decompile | ring scan fw 0x502c (13 rings, §13.1). Cache index from fw 0x200ec (hook 15). §19.2; COMPUTE.md:362-364. |
| layout.c:191 | X+0x38 | 0x129000 | ring 2 (compute) entries | SOURCED-decompile | X+0x18+0x10i = entries (§19.2). Ring 2 = compute (RENDER.md "Rings and queues"). Hook 16. |
| layout.c:196 | X+0xe4, X+0xe8 | 0x118000, 0x119000 zero pages | "in the order the firmware expects them" | SOURCED-decompile (pointer-ness only); meaning **UNKNOWN** | xfields scan (§13.2): X+0xe4 is indexed `+i*16` at fw 0x1ba3a. Nothing else recovered. The ordering claim in the comment has no source. |
| layout.c:198 | X+0x134 | 0x11c000 | geometry unit states | SOURCED-decompile | fw 0x54ec uses X+0x134+4 for engine 0 (stride 0x14). RENDER.md StartTA word 5. |
| layout.c:198 | X+0x138 | 0x11d000 | (unnamed) | SOURCED-decompile | fw 0x54ec uses **X+0x138+8 for engine 1 (fragment)**, stride 0x28 (fw FUN_00003b0c and FUN_00004f3c read +0x24). The driver's 3D path does not use it (§1.10). |
| layout.c:198 | X+0x13c | 0x11e000 | compute unit states | SOURCED-decompile | fw 0x54ec engine 2. fw case 0xb: entries of 0x18 bytes, +0xc status (3 = cancel). Hook 29. |
| layout.c:198 | X+0x140 | 0x11f000 zero page | — | SOURCED-decompile (pointer); meaning **UNKNOWN** | power condition `*(X[0x140]) != 2` (FENDER.md §14.3) |
| layout.c:199 | X+0x188 | 0x120000 | acknowledged MMU generations | SOURCED-decompile | fw 0x18530 (COMPUTE.md:398; DRIVER.md "Firmware facts used") |
| layout.c:201 | X+0xd8 | 0x127000 | control ring (ring 12) entries, 256×32 B | SOURCED-decompile | fw 0x200ec, 0x20904 (§19.2); hook 15 |
| layout.c:202-203 | X+0xdc / X+0xe0 | 0x147000 / 0x148000 (heap 0x57000 / 0x58000, via desc 1) | event ring control / entries | SOURCED-decompile | hook 25. Consumer +0, producer +0x20; fw spins while full (COMPUTE.md:1058-1068, fw ~0x98d2). |
| layout.c:204-205 | X+0xec / X+0xf0 | 0x165000 / 0x160000 (heap 0x75000 / 0x70000; 512×36 B, 5 pages) | SKU trace control / records | SOURCED-experiment `[DEBUG]` | hook 28; used only with U[0] debug bits (COMPUTE.md:407-409) |
| layout.c:206-207 | X+0xf4 / X+0xf8 | 0x158000 / 0x154000 (heap 0x68000 / 0x64000; 256×60 B, 4 pages) | firmware trace control / records | SOURCED-experiment | hook 27: experiment 26 aborted at fw 0x9480 without this "always-used" ring |
| layout.c:210 | X+0x301 (unaligned; byte X+0x303 = 0x13) | 0x00130000 | power-state struct | SOURCED-decompile (pointer) `[CONFLICT]` | fw reads `[X+0x301]+0x38` ("GPU powered", FENDER.md §13.2) and writes +0x10, +0x38, +0x1c0, +0x1088, +0x41f4, +0x4218, +0x4240, +0x42f0, +0x4310 (struct ≥0x4314 bytes). **0x130000 is heap 0x30000 = `HEAP_TA_RING`**, so the struct overlaps the TA ring, queue, queue state, command ring, status and pool (§1.9). Device heap dumps confirm firmware writes at heap 0x30010 (=4), 0x30038 (=1), 0x341f4, 0x34218, 0x34240, 0x342f0 (`out/resume/heap-compute.bin`, `heap9.bin`, `heap12.bin`). |
| (not written) | X+0x1ec, X+0x1fc | 0 | scalar counters | SOURCED-experiment | hook 20 corrects §13 (they are not pointers) |

### 1.4 Device context P (heap 0x2000, fw VA 0x102000; `layout.c`)

| file:line | field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:218 | P+0x00 | 0x600000000 | "GPU address window" | SOURCED-decompile; meaning **UNKNOWN** | kext17 0x…6012bd0..6012bec constants (COMPUTE.md:450-462; hook 31: "complete hardware semantics are not yet established") |
| layout.c:219 | P+0x08 | 0xffc00000 | same | SOURCED-decompile; meaning UNKNOWN | same |
| layout.c:220 | P+0x10 | pds_base = 0x2a00000000 | PDS exec base | SOURCED-experiment | kext17 uses 0x300000000. Experiment 49 (fault at PDS base+0x400000) and experiment 67 show offsets are relative to it. Driver bases verified by driver4-selftest4-heaps.log (DRIVER.md:100-102). |
| layout.c:221 | P+0x18 | usc_base = 0x2c00000000 | USC code base | SOURCED-experiment | experiment 67 (fault at USC base+0x4000, COMPUTE.md:236); DRIVER.md:100-102 |
| layout.c:222 | P+0x20 | 0x1ffff8000 | window | SOURCED-decompile; meaning UNKNOWN | kext17, as P+0x00 |
| layout.c:104-108, 162-170 | P+0x640 I/O table | 0x18-byte entries {pa, fw va (fw writes), size, +0x10=0, +0x14=1}, 7 entries | I/O mappings | SOURCED-decompile | fw 0x1a198 (FENDER.md §15.4). +0x14≠0 → attr 0x21b (device RW) (§16.2, fw 0x247c0). |
| layout.c:110-111, 224 | entry 0 | 0x201d00000 / 0x5000 | Fender | SOURCED-decompile | kext17 `configureDevice` FenderRegs (FENDER.md §1.2); hook 13 (E0PA/ESIZE) |
| layout.c:112-113, 225 | entry 3 | 0x201000000 / 0x20000 | RGX | SOURCED-decompile | kext17 RGXRegs (§1.2). Init-program offsets are relative to entry 3 (README.md:180); hook 13. |
| layout.c:101, 226-229 | entries 1, 2, 4, 5, 6 | 128 KiB RAM each at heap+0x320000+0x20000·k | "RAM behind unused I/O entries" | SOURCED-experiment `[PLACEHOLDER]` | agx-init12. iOS (order medium confidence, §1.2/§15.4): 1 AICTimerRegs 0x20e101000, 2 AICSWIntRegs (kext this+0x4490), 4 UVD/unused, 5 DisplayUnderrunWA 0x200800000/0x1000, 6 TempSensorRegs 0x20e0c0020/0x1000. Firmware timer reads and AP software interrupts land in RAM. |
| layout.c:233-235 | P+0x16c0/+0x16c4/+0x16c8 | 1, 1, 1 | one scheduling unit per engine | SOURCED-experiment | hook 22: fw 0x17f54..0x17f78 copies them to shared+0x774..; zero blocks microsequence execution (fw 0x99d0) |
| (not written) | P+0x93c, P+0x944 | 0 | — | **UNKNOWN** (known omission) | kext17 writes P+0x93c from global 0x…b3686a bit 1 and P+0x944 = 1 (vtable+0x798) (FENDER.md §18.1, §19.5). With zeros, fw 0x6b12 skips its own Fender request and only sets power_state+0x38 = 1. The driver powers Fender from the AP instead. |

### 1.5 GPU MMU (`layout.c`, `apple.c`)

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:116 | PC entry | `(pa>>12)<<4 \| 1` | PC valid | SOURCED-decompile | kext17 AGXGartG3ThruG9 0x…60365a8..6036668 (COMPUTE.md:413-421); hook 26 |
| layout.c:117 | PD entry | `pa \| 3` | valid, 16 KiB leaf | SOURCED-decompile | same |
| layout.c:118-119 | PT valid / SLC bypass | 0x1 / 0x8 | — | SOURCED-decompile | flag method kext17 0x…60364d0 (hook 35). SLC bypass alone had no effect (experiment 35). |
| layout.c:120 | PT bit 2 | 0x4 | "cache coherent" | DERIVED `[STALE-COMMENT]` | hook 37 calls flags 13 "valid, read-only, SLC bypass", i.e. bit 2 = read-only. The CC name comes from Rogue. Used only in the reference layout (gpu_root == 0). |
| layout.c:241 | T+0x7dc | 0x142000 (heap 0x52000) | MMU generations | SOURCED-decompile | hook 18 (abort 0x18592 without it) |
| layout.c:242 | T+0x7e0 | 0x126000 | 256 × u64 context roots | SOURCED-decompile | fw 0x18352/0x18376 (FENDER.md §19.1); hook 14 |
| layout.c:243 | root[0] | kernel VM page-table root | context 0 root | SOURCED-experiment | driver2 logs (DRIVER.md:61-67) |
| layout.c:244; apple.c:587, 854 | gen[0] (+= 0x400000) | 0x400000 | full PC/PD/PT invalidation | SOURCED-decompile | fw 0x18530: difference in bits ≥22 → invalidate command 4 (hook 30) |
| apple.c:584-585 | RGX 0xe140 / 0xe148 | 0 / root>>12 | MMU_CBASE_MAPPING_CONTEXT / MAPPING | SOURCED-experiment | driver3-selftest4.log (DRIVER.md:75-77). Same registers as kext17's init program (+0x708 → 0x…6030958, FENDER.md §19.5). IMG names in rgx_cr_defs_km.h. Readback: experiment `mmu-clock-on.log`. |
| layout.c:255-267 | reference pages (gpu_root == 0 only) | PD index 1 → VA 0x200000; PC index 12 → VA 0x300000000 | reference layout | SOURCED-experiment | hooks 26/37/46. Not used by the driver at runtime. |

### 1.6 Rings, queues and job slots (compute; `layout.c`, `apple.c`)

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:99 | RING_ENTRIES | 256 | — | SOURCED-decompile | work-ring consumer fw 0x20116..0x201e4 (§19.2). Index wrap `+1 & 0xff` at fw 0x1ff88 (COMPUTE.md:1074-1079). |
| layout.c:100 | WORK_ENTRY_SIZE | 20 | — | SOURCED-decompile | same |
| layout.c:273, 413 | work +0x08 | queue fw VA | queue pointer | SOURCED-decompile | §19.2; hook 16 |
| layout.c:274, 414 | work +0x0c | 2 | engine: compute | SOURCED-decompile | "A ring entry's +0xc must equal the ring's engine" (RENDER.md:331-338) |
| layout.c:275, 415 | work +0x10 (u16) | seq % 256 | command-ring head after the job | SOURCED-experiment | wrap fix (COMPUTE.md:1074-1080, 700 jobs pass) |
| (implicit 0) | work +0x12 | 0 | scheduling slot | SOURCED-experiment | slot → {queue, engine} table fw 0x5b930 (stride 0x28). A mismatched slot crashes at fw 0xf01a (`driver7-ta.log`, RENDER.md:412-416). |
| (implicit 0) | work +0x13 | 0 | "extra flag" | **UNKNOWN** | COMPUTE.md:362 "full semantics not recovered" |
| layout.c:277-278 | queue +0x00 / +0x04 | state / command ring | — | SOURCED-decompile | hook 16; COMPUTE.md:366-369 |
| layout.c:279 | queue +0x0c | 0x140000 | scheduling pool, 128 × 44 B | SOURCED-experiment | hook 17 (abort 0xe706 without it) |
| layout.c:280 | queue +0x44 | 1 | available hardware-unit mask | SOURCED-experiment | hook 23 (abort 0xfe84). fw case 0xc ORs/restores it. |
| layout.c:281 | queue +0x88 | 0x12e000 | status/tracking (≥0x24 B) | SOURCED-decompile | §19.2; hook 16 |
| layout.c:282 | queue state +0x50 | 256 | capacity | SOURCED-experiment | hook 16; COMPUTE.md:369 |
| layout.c:283, 410 | command ring entry | command fw VA | — | SOURCED-decompile | hook 16 |
| layout.c:93-98 | job slots | 16 × 0x1000 at heap 0x80000 (fw 0x170000); cmd +0, useq +0x400, CDM args +0x500 | per-job slots | DERIVED | driver choice. Validated by driver3-selftest3 and 700 jobs. CDM args need 0x48 bytes (fw case 0xb reads 18 words). |
| layout.c:658-661; apple.c:665-667 | producer index | seq % 256 at ring indices +8 | — | SOURCED-decompile | fw 0x1ff88 |
| layout.c:664-672, 694-697, 734-737 | ring i index words | 0x11000+0x10i; producer +8 | — | SOURCED-decompile | §19.2 |
| apple.c:928-930 | fragment retired | ring 1 consumer & 0xff == frag_seq & 0xff | retirement before next geometry | DERIVED | retirement unregisters the free list (comment: fw 0x13144, crash fw 0x1703c; RENDER.md:679-695). Verified `uapi21-clean.log`. |

### 1.7 Compute command and microsequence (`layout.c:286-416`)

Comparison basis: kext17 compute builder `FUN_fffffff006035960` (StartCompute 0x12 words, FinalizeCompute 0xc words) and fw interpreter 0x9f04, cases 0xb and 0xc.

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:332 | cmd +0x000 | 3 | compute | SOURCED-decompile | command types (RENDER.md:336-338; kext17 trace emitter FUN_…9284); hook 16 |
| (not written) | cmd +0x004 (u64) | 0 | — | DERIVED | kext17 passes cmd+4 as StartCompute w15/w16 (the cancel comparison, below) |
| (not written) | cmd +0x010 | 0 | context id | DERIVED | kext17 StartCompute w5 = cmd+0x10 → fw writes RGX 0xf07a, 0x136e, 0x136f |
| layout.c:333 | cmd +0x014 | 0x143000 | context | SOURCED-experiment | hook 19/20 (abort 0x13414: cache maintenance on cmd+0x14) |
| layout.c:334-335 | cmd +0x1e8 / +0x1ec | useq / 0x80 | microsequence ptr/size | SOURCED-decompile | kext17 builder stores the sequence at +0x1e8/+0x1ec |
| layout.c:336 | cmd +0x26c | 0x145004 | host stamp address | SOURCED-experiment | hook 25 (abort 0x9822 without it); experiment 25/46 |
| layout.c:337 | cmd +0x274 | seq | stamp value and scheduling token | SOURCED-experiment | hook 25. Token bits 8–14 select the pool entry (RENDER.md:412-416). Compute writes the full seq, so pool entries 1..127 are used after job 255, whereas TA/3D mask with 0xff (DERIVED inconsistency). |
| (zero) | cmd +0x278 | 0 | scheduling slot | SOURCED-experiment | RENDER.md:412-416 |
| layout.c:407 | cmd +0x2c4 | (flag word) | Start/Finalize flag | SOURCED-decompile | kext17 StartCompute w14 = FinalizeCompute w10 = cmd+0x2c4 (COMPUTE.md:946-952) |
| — | command size | 0x2c8 | — | SOURCED-decompile | queue parser cache-clean size (RENDER.md:416-418) |
| layout.c:311 | useq+0x00 | 11 | StartCompute | SOURCED-decompile | fw case 0xb (handler 0xa61c); kext17 op 0xb |
| layout.c:312 | +0x04 (w1) | 0x14c000 (zero page) | "CDM regs" | SOURCED-decompile (role); values see §1.8 | fw case 0xb: w1[0] → RGX 0x4c0, w1[1] → RGX 0x4c8. kext17: cmd+0x18. |
| layout.c:313 | +0x08 (w2) | CDM args | — | SOURCED-decompile | fw case 0xb: 0x498, 0x4b8, 0x480, then 6 × 0x11040 per cluster. kext17: cmd+0x68. |
| layout.c:314 | +0x0c (w3) | 0x11e000 | "shared unit states" | SOURCED-decompile | fw 0x54ec (engine 2 = X+0x13c). kext17 w3 = global unit array. Hook 29. The meaning in the comment is sourced. |
| (zero) | +0x10 (w4) | 0 | — | DERIVED | kext17: channel buffer (param_1[0x12]). fw stores it at unit+0x10. |
| (zero) | +0x14 (w5) | 0 | context id | DERIVED | → RGX 0xf07a (fw case 0xb) |
| (zero) | +0x18..+0x28 (w6–w10) | 0 | — | DERIVED | kext17: misc state and a trace id (w9 = cmd+0x27c) |
| layout.c:315 | +0x2c (w11) | 0x143000 (shared) | context state | SOURCED-decompile (role); location DERIVED | fw: ctx[0]==0 → kick RGX 0x478 = 1, else resume (fw 0x16176). ctx+0x38/+0x3c/+0x40 → RGX 0x4a8/0x4ac/0x4b0. kext17 uses cmd+0x1f0 per command; the driver shares one page across all jobs and VMs. |
| layout.c:316 | +0x38 (w14) | per job: cmd+0x2c4; reference: 0x146100 | flag | SOURCED-decompile | as above |
| (zero) | +0x3c/+0x40 (w15/16) | 0, 0 | — | DERIVED | kext17 = u64 at cmd+4 |
| layout.c:317, 346 | +0x44 (w17) → 0x146108 = {1, 0} | — | (none in code; hook 26: "guard/deadline pointers") | DERIVED | fw case 0xb kicks only if the 64-bit value at w17 exceeds {w15, w16}; otherwise it sets the flag (skip). kext17 points w17 at a context buffer +0x6c. The value 1 comes from hook 26. |
| layout.c:319 | +0x48 | 0x100 (4<<6) | WaitIRQ COMPUTE_FINISHED | SOURCED-experiment | hooks 38/39/44; trace 0x102 status 4 (COMPUTE.md:493-502). Header>>6 = mask (fw 0xa3fa). |
| layout.c:321 | +0x4c | 12 | FinalizeCompute | SOURCED-decompile | fw case 0xc |
| layout.c:322 | +0x50 (w1) | 0x11e000 | unit states | SOURCED-experiment | hook 29 |
| (zero) | +0x54 (w2) | 0 | — | DERIVED | kext17: channel buffer |
| (zero) | +0x58 (w3) | 0 | context id → flush RGX 0xe230 = id<<2\|0x803 | DERIVED | fw case 0xc; kext17 cmd+0x10 |
| (zero) | +0x5c (w4) | 0 | — | **UNKNOWN** `[MISMATCH-iOS]` | kext17: cmd+0x1f0 (context). Passed to fw 0xd7c0 on the context-store path. |
| layout.c:323-324 | +0x68/+0x6c (w7/w8) | 0x145000 / seq | first completion stamp | SOURCED-experiment | hooks 24/26; experiment 46. kext17: u64 at cmd+0x270. |
| (zero) | +0x70 (w9) | 0 | — | **UNKNOWN** `[MISMATCH-iOS]` | kext17 computes "bytes to skip" = 0x30 (size of FinalizeCompute; TA uses 0x3c, 3D 0x4c, which the driver does set). fw case 0xc advances the interpreter by w9 on the context-store path, so 0 would re-run Finalize. |
| layout.c:325 | +0x74 (w10) | flag | — | SOURCED-decompile | as w14 |
| (zero) | +0x78 (w11) | 0 | — | **UNKNOWN** `[MISMATCH-iOS]` | kext17: cmd+0x2ac. fw case 0xc writes through it when RGX 0x4a0 (CDM_CONTEXT_STORE_STATUS) bit 1 is set, i.e. through a NULL firmware pointer here. |
| layout.c:327 | +0x7c | 2 | End | SOURCED-decompile | experiments 21/25/46 |
| — | sequence | Start 0x48 + Wait 4 + Finalize 0x30 + End 4 = 0x80 | — | SOURCED-decompile | kext17 word counts. iOS also emits timestamp ops (op 3, FUN_fffffff006049284), omitted (COMPUTE.md:852). |

### 1.8 CDM arguments, context state, Q, U, V (`layout.c`, `apple.c`)

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:296 | args +0x00 → RGX 0x498/0x49c | ctx_state (UAPI `cdm_context_state_base_addr`) | context/storage base | SOURCED-experiment | experiments 40 (no fault) and 42. kext10 `AGXCLChannelG9G::generateRegisterList`: 0x498 = descriptor+0xf8. The size the CDM needs there is UNKNOWN (tests use 16 KiB). |
| layout.c:297-298 | args +0x08/+0x0c → RGX 0x4b8/0x4bc | 0x201000 / 0x201010 | "terminate PDS code/data (the driver's HALT program)" | **UNKNOWN** `[PLACEHOLDER]` | provisional since hook 26 (COMPUTE.md:435 "old provisional values retained"). Mesa cr.xml CDM_TERMINATE_PDS: code_addr bits 4–31, data_addr bits 36–63, "sent to PDS on Context Store". PDS addresses on A10 are PDS-base relative (experiments 49/67), so these point at PDS base+0x201000 (userspace PDS heap in user VMs), **not** at the HALT at GPU VA 0x201000. They have never been shown to be fetched. kext10 takes 0x4b8 from descriptor+0xd8. |
| layout.c:299 | args +0x10 → RGX 0x480 | stream | CDM stream base | SOURCED-experiment | experiments 40/41/42 (fault 0x0000400000000119 at the injected VA); kext10: 0x480 = descriptor+0xa0 |
| (zero) | args +0x18..+0x47 → RGX 0x11040 ×6 (0x11ff8 = 0..5) | 0 | (not mentioned in code) | SOURCED-decompile | fw case 0xb. kext10 generateRegisterList writes 0 when its per-cluster buffer size (descriptor+0x128) is 0, else `base + i·stride \| 1`. Needed once kernels use that buffer (meaning UNKNOWN, possibly scratch). |
| (zero page) | 0x14c000[0] → RGX 0x4c0 | 0 | CDM_TERMINATE_PDS1 | DERIVED | IMG name 0x4c0 (rgx_cr_defs_km.h). kext10: descriptor+0xe0. Zero = no terminate task sizes. |
| (zero page) | 0x14c000[1] → RGX 0x4c8 | 0 | CDM item mode | SOURCED-decompile | kext10 generateRegisterList: item-mode table {0, 2, 3} at kext 0x301c, index 0 → 0. Tested 0/2/3 with no group-ID effect (COMPUTE.md:788-789). |
| layout.c:350-351 | ctx +0x38/+0x3c → RGX 0x4a8/0x4ac | 0x201000 / 0x201010 | "Context store/load PDS program (RGX_CDM_CONTEXT_PDS0)" | name SOURCED-decompile; value **UNKNOWN** `[PLACEHOLDER]` | fw case 0xb writes ctx[0xe]/[0xf] to 0x4a8/0x4ac; IMG name RGX_CR_CDM_CONTEXT_PDS0 = 0x4a8 (rgx_cr_defs_km.h). Value from hook 33, same addressing caveat as 0x4b8. iOS builds a real program (Metal `ContextSwitcher::setupComputeCommand` 0x21c76c83c, `PDSEncoderGen1::EncodeContextSwitchPDSProgram` 0x21c7bdd18: DOUTWs + DOUTU + HALT kicking a USC store task). |
| (zero) | ctx +0x40 → RGX 0x4b0 | 0 | CDM_CONTEXT_PDS1 | **UNKNOWN** | fw case 0xb |
| (zero) | ctx +0x00 | 0 | fresh start | SOURCED-decompile | fw case 0xb. If the firmware ever stores a context, a non-zero ctx[0] would send every later job down the resume path (fw 0x16176), because the page is shared. |
| layout.c:354 | Q[0] (u64) → RGX 0xe240 | 0x203000 | flush scratch/fence address | SOURCED-decompile | fw 0x1bb0a copies to 0x8dd50; 0x597c..0x599c programs 0xe240. Experiment 44 write fault 0xff251 fixed by hook 46. |
| layout.c:348 | reference args | stream 0x200000, ctx 0x202000 | reference job | SOURCED-experiment | hooks 42/46 |
| layout.c:387 | U[0] | 3 | debug flags | SOURCED-experiment `[DEBUG]` | hook 28 (U+0 → shared debug flags, fw global 0x3004c). Bit 0 gates SKU trace events 7/8/0x16/0x102..., bit 1 cancel-path events (fw case 0xb/0xc). Enables writes into the SKU ring. |
| layout.c:388-389 | V+0x455c / V+0x4560 | 0x124000 / 0x125000 | mapping-update ring control / entries | SOURCED-decompile | fw 0x181ee (FENDER.md §14.1) |
| layout.c:390 | V+0x45b4 | 1 | engine scheduler init | SOURCED-decompile | fw 0x1b688 → 0xd980 (hook 19) |

### 1.9 Event ring, stamps, completion

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:76 | HEAP_EVENT_RING | control 0x57000; 256 × 0x24 B at +0x1000 | event ring | SOURCED-decompile | COMPUTE.md:1058-1068 (fw ~0x98d2); hook 25 |
| layout.c:679-687; apple.c:710-713 | consumer +0x00 := producer +0x20 | — | acknowledge all events | SOURCED-experiment | hang at job 256 fixed (COMPUTE.md:1058-1084) |
| layout.c:739-742 | compute completion | HEAP_STAMP+4 (via cmd+0x26c) | — | SOURCED-experiment | experiments 25/46 |
| layout.c:699-702, 529-530 | geometry stamp | HEAP_STAMP+0x10 (FinalizeTA w11/w12) | — | SOURCED-experiment | driver20 (RENDER.md:544-548) |
| layout.c:689-692, 629-630 | fragment stamp | HEAP_STAMP+0x20 (Finalize3D w2/w3) | — | SOURCED-experiment | driver22 |
| apple.c:136 | poll | 1 ms | "firmware sends no completion message" | SOURCED-experiment | DRIVER.md:115-116. Possibly a consequence of the RAM-backed AICSWInt entry (§1.4). |

### 1.10 TA (geometry) path (`layout.c:424-543`, `apple.c:954-1006`)

Comparison basis: kext17 TA builder `FUN_fffffff006035fa4` (StartTA 0x1a words, op 4 trace, FinalizeTA 0xf words), fw case 5 (0xa88c) and case 6, and kext17 free-list builder `FUN_fffffff006040ba8`.

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:50-65 | TA heap areas | ring 0x30000, queue 0x32000, state 0x32200, cmd ring 0x32400, status 0x32800, pool 0x33000 (128×44), cmd 0x35000 (0x600), useq 0x35600, regs 0x35700/0x35800, scratch 0x35a00, free list 0x36000 (0x74), PM slot 0x36100 (0x100), ctx 0x36200 (0x84), PM state 0x36300, PM header 0x36400 | — | DERIVED `[CONFLICT]` | sizes from RENDER.md:340-344, 399, 416-418. **0x30000–0x34600 lies inside the power-state struct at fw VA 0x130000 (≥0x4314 B)**: the TA ring entry 0 head (+0x10), entry 2 head (+0x38), entry 22 queue pointer (+0x1c0) and pool entries ~104-111 (+0x41f4..+0x4314) are firmware power fields (§1.3). |
| layout.c:426 | X+0x18 | TA ring | ring 0 entries | SOURCED-decompile | RENDER.md:331-334 |
| layout.c:428-433 | TA queue fields | as compute; +0x44 = 1; state +0x50 = 256 | — | SOURCED-experiment | driver20 |
| layout.c:540-542 | work +0x0c / +0x12 | 0 / slot 1 | engine geometry / slot | SOURCED-experiment | driver7 crash (fw 0xf01a) when slots mismatch |
| layout.c:487 | cmd +0x000 | 0 | geometry | SOURCED-decompile | RENDER.md:336-341 (dispatcher fw 0x115fc) |
| layout.c:488 | cmd +0x00c | 0 | context id → CONTEXT_MAPPING0 0xf078 | SOURCED-decompile (role) | RENDER.md:357; kext17 w8 = cmd+0xc |
| layout.c:489 | cmd +0x014 | TA context (0x84 B) | — | SOURCED-decompile | RENDER.md:341 |
| layout.c:490 | cmd +0x018 | 0 | free-list index | SOURCED-decompile | fw 0x1703c reloads on change; table[cmd+0x18] (RENDER.md:691-695) |
| layout.c:491-492 | cmd +0x020 / +0x024 | free list / PM slot | — | SOURCED-decompile | RENDER.md:342; kext17 StartTA w3 = cmd+0x20 |
| layout.c:493-494 | cmd +0x464 / +0x468 | useq / 0xb0 | — | SOURCED-decompile | kext17 stores the sequence at +0x464/+0x468. 0x68+4+0x3c+4 = 0xb0 (iOS's 4-word op 4 trace omitted). |
| layout.c:500 | cmd +0x550 | scratch+0x80 | host stamp | DERIVED | by analogy with compute +0x26c (same descriptor layout shifted by 0x2e4). kext17 FinalizeTA w11/w12 read u64 cmd+0x554 (RENDER.md:343 says "+0x554/+0x558 stamp address/value"). |
| layout.c:501 | cmd +0x558 | seq & 0xff | token (bits 8–14 = entry) | SOURCED-experiment | RENDER.md:412-416 |
| layout.c:502 | cmd +0x55c (byte) | 1 | scheduling slot | SOURCED-experiment | same |
| layout.c:503 | cmd +0x568 | seq | sequence | SOURCED-decompile | kext17 StartTA w20 / FinalizeTA w10 = cmd+0x568; fw trace arguments (FUN_000028f8, FUN_000222ac) |
| layout.c:471 | FL +0x18 | stack base | — | SOURCED-decompile | kext17 FUN_fffffff006040ba8; fw 0x16634 → RGX 0x210 |
| layout.c:472 | FL +0x20 | pages × 4 | stack size | SOURCED-decompile (role) | kext17 +0x20 = size |
| layout.c:473 | FL +0x24 | 0 | bottom | SOURCED-decompile | kext17; fw → 0x220 |
| layout.c:474 | FL +0x28 | pages / 32 | (not explained) | **UNKNOWN** | kext17 writes a different object field (+0x130) here; units not recovered |
| layout.c:475 | FL +0x3c | PM state page | — | DERIVED | kext17: firmware address of a buffer (obj+0xb8) |
| layout.c:476 | FL +0x40 | pages − 1 | top (pre-filled stack) | SOURCED-experiment | kext17 writes 0xffffffff (empty; fw grows from 128 KiB blocks). Pre-fill validated driver20/21 (PM stack top 0x3ff → 0x3dd). |
| layout.c:477 | FL +0x50 | PM state +0x40 | — | DERIVED | kext17: firmware address of another buffer |
| (zero) | FL +0x0c, +0x34 (u64), +0x44, +0x64, +0x68, +0x6c (u64) | 0 | — | **UNKNOWN** `[MISMATCH-iOS]` | kext17 fills them (+0x64/+0x68 as sizes <<5, +0x6c from a vtable call) |
| layout.c:480-482 | PM slot +0xa0/+0xa8/+0xb0 | MLIST / MTILE / VHEAP | → RGX 0x2d8 / 0x240 / 0x248 | SOURCED-decompile | fw StartTA case 5 (RENDER.md:353) |
| layout.c:483 | PM slot +0xb8 | job->skip (0) | skip kick | SOURCED-decompile | same |
| layout.c:484 | PM slot +0xc0 | PM header +0x40 | "header" | DERIVED (offset +0x40 UNKNOWN) | RENDER.md:399 |
| layout.c:506 | StartTA +0x00 | 5 | StartTA | SOURCED-decompile | fw case 5; kext17 op 5 |
| layout.c:507-510 | w1–w4 | regs32, regs64, FL, PM slot | — | SOURCED-decompile | RENDER.md:346-353; kext17 cmd+0x3b4/+0x30 (constants at 0x…54e8b78) |
| layout.c:511 | w5 | X+0x134 page + 4 | geometry unit states | SOURCED-decompile | fw 0x54ec engine 0; kext17 global + 4 |
| layout.c:512 | w6 | scratch+0x40 | channel | DERIVED | kext17: channel buffer |
| layout.c:513 | w7 | scratch+0x00 | skip flag | DERIVED | kext17: cmd+0x538 |
| layout.c:514-515 | w16 / w17 | scratch+0x10 / +0x20 (0) | 0 = fresh PM state | SOURCED-decompile (semantics) | RENDER.md:359. kext17: cmd+0x474/+0x574 (constants 0x…54e8b80). |
| layout.c:516 | w20 | seq | — | SOURCED-decompile | kext17: cmd+0x568 |
| layout.c:463-464, 517 | w22/w23 = 0; w24 → {~0, ~0} | — | cancel threshold | DERIVED | RENDER.md:356 ("skip when w22/23 ≥ {lo,hi} at w24"). kext17: cmd+4 vs context buffer+0x6c. |
| (zero) | w8–w15, w18, w19, w21, w25 | 0 | — | DERIVED | kext17: ctx id, free-list index (param_3+0xce0), misc state bytes |
| layout.c:519 | Wait | 0xe0<<6 | TA_FINISHED \| TA_TERMINATE \| PM_OUT_OF_MEMORY | DERIVED | RENDER.md:368-370 (iOS geometry waits on 0x20). Union chosen and validated by driver20. Waiting on PM_OOM means an out-of-memory TA "completes" silently, with no growth. iOS's TA wait op (vtable +0x180) not read. |
| layout.c:521-532 | FinalizeTA 6; w1 slot, w2 FL, w3 units+4, w4 channel, w5 skip, w6 ctx id 0, w7 0, w8 resume, w9 0, w10 seq | — | — | SOURCED-decompile (layout) | kext17 FinalizeTA words match position for position |
| layout.c:529-530 | w11/w12 | HEAP_STAMP+0x10 / seq | stamp | SOURCED-experiment | driver20. kext17: u64 cmd+0x554. |
| layout.c:531 | w13 | 0x3c | "to End on a store" | SOURCED-decompile | kext17: size of FinalizeTA |
| layout.c:532 | w14 | PM state +0x80 | state block | DERIVED | kext17: cmd+0x5a4 |
| apple.c:975-1006 | geom register mapping (regs32[0..7] → 0xc78, 0xc88, 0xc98, 0xc18, 0xc08, 0xc10, 0xc20, 0xc28; regs64 → 0xc90 … 0x11030) | from Rogue cmd, HWRT, Apple extension | — | SOURCED-decompile (slot → register) | fw case 5 (tools/regflow.py, RENDER.md:350-351). Values come from powervr/Mesa (DERIVED); they agree with the kext10 formulas at 64×64. |
| apple.c:999-1001 | free-list start | base + (offset & ~15), pages + (offset & 15)/4 | top of stack, 16-byte aligned | DERIVED | fw masks the base to 16 bytes (RENDER.md:353) |

TA self-test values (`apple.c:1400-1470`, `apple_selftest>=5` only, all `[DEBUG]`):

| file:line | register | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| apple.c:1403 | 0xc78 | 0x88 | — | SOURCED-decompile | kext10 constant (RENDER.md:386) |
| apple.c:1404 | 0xc88 | 2 | PPP_CTRL | SOURCED-decompile | kext10 "2 \| userspace bits"; masks name PPP_CTRL (rgx-masks.log) |
| apple.c:1405-1409 | 0xc98, 0xc18, 0xc08/0xc10, 0xc20 | 0x3f003f, 0x1001, 0x10100c, 16 | screen, tiles, macrotiles | SOURCED-decompile | kext10 `AGXRenderTargetMemoryG5::halComputeGeometry` formulas (RENDER.md:377-385) |
| apple.c:1410 | 0xc28 | 0x20000 | TE_PSG (completeonterminate) | SOURCED-decompile | kext10 constant. The bit name is Rogue (RENDER.md:519). |
| apple.c:1415 | 0xc90 | 0x640 | "PPP_CTRL" | **UNKNOWN** `[STALE-COMMENT]` | the record's 0x470 value read 0x28 bytes off (RENDER.md:456-468, 525-536). 0xc90 is PDS_CTRL (kext10: 0x1e3ce508). Superseded mapping used for the "empty" run. |
| apple.c:1420 | 0x428 | 0x0003000524001002 | "PDS control" | **UNKNOWN** `[STALE-COMMENT]` | actually the VDM context store task 0 (same superseded mapping). 0x428 is a 16-byte-aligned address register (rgx-masks.log). |
| apple.c:1421 | 0xcc0 | 0x900 | "TE_PSG" | **UNKNOWN** `[STALE-COMMENT]` | actually store task 1 (PDS code 0x900). 0xcc0 is an address (masks). |
| apple.c:1418-1419 | 0xc00 / 0xc80 | 0 / 0x88 | one sample / sample positions | SOURCED-decompile | kext10 (RENDER.md:381) |
| apple.c:1442 | 0xc90 | 0x1e3ce508 | PDS_CTRL | SOURCED-decompile | kext10 constant (RENDER.md:470-472, 512) |
| apple.c:1443-1457 | 0x428, 0xcc0, VDM tasks, 0x470, 0x418, 0xf058..0xf070 | record values | — | SOURCED-capture | iPadOS record R9+0x28 (`out/ios-render/base`) mapped per kext10 `AGXTACommandDescriptor::loadTAFields` (RENDER.md:525-536). driver20 completes. |
| apple.c:1270-1284 | self-test RT layout (0x40000000, RT_* offsets, 4 MiB PB, 4 KiB PM pages) | — | — | DERIVED | driver choice. 4 KiB PM pages: free-list entries are PA>>12 (RENDER.md:392-394). |
| apple.c:1779-1784 | empty stream | PPP_STATE header 0x300\|hi, lo; 0xc0000000; PPP words 0x02000000 0x00040001 0 | PPP terminate + STREAM_TERMINATE | SOURCED-capture | iPadOS stream end (R10+0x230/0x238; R23+0x120) in `out/ios-render*`. Header = Mesa `pres_terminate` (RENDER.md:425-431, 443-446). |
| apple.c:1786-1845 | variants (BIT(9)\|BIT(1), BIT(17)\|1, 0x915, 0x910, 0x920, RT_PDS_STATE, …) | — | experiment knobs | SOURCED-experiment `[DEBUG]` | driver13–19 (RENDER.md:443-523). All negative. |

### 1.11 3D (fragment) path (`layout.c:545-652`, `apple.c:1008-1044`, `1480-1525`)

Comparison basis: kext17 3D builder `FUN_fffffff006033898` (Start3D 0x1d words, Finalize3D 0x13 words). Offset constants read from the kext ELF at 0x…54e8b28: {0x3b0, 0x68}, {0x860, 0x864}, {0x748, 0x8c0}.

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| layout.c:548 | X+0x28 | 3D ring | ring 1 | SOURCED-decompile | RENDER.md:331-334 |
| layout.c:550-555, 648-651 | queue; work +0xc = 1, +0x12 = slot 2 | — | — | SOURCED-experiment | driver22 |
| layout.c:597 | cmd +0x000 | 1 | fragment | SOURCED-decompile | RENDER.md:336-337 |
| layout.c:598-599 | cmd +0x020 / +0x024 | geometry FL / PM slot | read at retirement | SOURCED-experiment | fw 0x12b98 (RENDER.md:679-680); uapi runs |
| layout.c:600-601 | cmd +0x014 / +0x018 | useq / 0xc8 | — | SOURCED-decompile | kext17 stores at +0x14/+0x18. 0x74+4+0x4c+4 = 0xc8. |
| layout.c:602 | cmd +0x01c | 3D context (0x84) | — | SOURCED-experiment | driver22 (RENDER.md:582-584) |
| layout.c:586-588 | cmd +0x3b0 / +0x68 | regs32 / regs64 | register blocks | SOURCED-decompile | kext17 constants {0x3b0, 0x68}; Start3D loads (fw 0xb7fc, RENDER.md:192-202) |
| layout.c:604-607 | cmd +0x89c / +0x8a4 / +0x8a8 / +0x8b4 | stamp / seq&0xff / slot 2 / seq | scheduling descriptor | +0x8b4 SOURCED-decompile; rest DERIVED | kext17 Start3D w25 / Finalize3D w1 = cmd+0x8b4. The others by analogy with geometry (RENDER.md:585-588, "fw 0xe184"). |
| layout.c:610 | Start3D +0x00 | 7 | Start3D | SOURCED-decompile | fw case 7 (0xadb2); kext17 op 7 |
| layout.c:613 | w3 | PM slot | — | SOURCED-decompile | fw 0x1622c (RENDER.md:591-592) |
| layout.c:580, 614 | w4 | **X+0x134 page + 8** | "unit states (the X+0x134 page) + 8" | DERIVED `[MISMATCH-iOS]` (likely wrong) | fw 0x54ec uses **X+0x138 + 8** for engine 1, with a 0x28 stride. kext17 passes a different global (+0x4c, vs +0x4b for TA) + 8. The driver's pointer overlaps TA unit 0 (+4..+0x18), whose +8 status word the firmware polls (FUN_00003b0c, FUN_00004f3c). |
| layout.c:615-616 | w5 / w6 | scratch+0 / +0x10 | partial-render counters | DERIVED | kext17: cmd+0x860/+0x864 |
| layout.c:617 | w7 | scratch+0x20 | skip | DERIVED | kext17: cmd+0x890 |
| layout.c:618 | w8 | scratch+0x30 | channel | DERIVED | kext17: channel buffer |
| layout.c:619 | w9 | cmd | — | SOURCED-decompile | kext17 w9 = command |
| layout.c:620 | w18 | scratch+0x40 | "non-zero defers the kick" | DERIVED | kext17: cmd+0x748 |
| layout.c:621 | w19 | cmd+0x8c0 | — | SOURCED-decompile | kext17: cmd+0x8c0 |
| layout.c:622 | w25 | seq | — | SOURCED-decompile | kext17: cmd+0x8b4 |
| layout.c:589-590, 623 | w26/w27 = 0; w28 → {~0, ~0} | cancel threshold | — | DERIVED | kext17: cmd+4 vs context buffer+0x6c |
| (zero) | w10–w17, w20–w24 | 0 | — | DERIVED | kext17: ctx id (cmd+0xc), state bytes, cmd+0x8ac … |
| layout.c:625 | Wait | 0x8<<6 | PIXELBE_END_RENDER | SOURCED-experiment | driver22/27 (RENDER.md:598, 638-641) |
| layout.c:627-643 | Finalize3D 8; w1 seq, w4 slot, w6 = 1, w7 units+8, w8 skip, w9 partial, w10 channel, w11 cmd | — | — | SOURCED-decompile (layout) | kext17 positions match. w6 = 1 is the kext17 constant. w7 has the same mismatch as Start3D w4. |
| layout.c:629-630 | w2/w3 | HEAP_STAMP+0x20 / seq | stamp | SOURCED-experiment | driver22. kext17: u64 cmd+0x8a0. |
| layout.c:632 | w5 | scratch+0x50 | counter block | DERIVED | kext17: param_3+0x740 buffer |
| layout.c:639 | w13 | **cmd+0x8c0** | "w13: command+0x8c0" (RENDER.md:602) | DERIVED `[MISMATCH-iOS]` | kext17 Finalize3D w13 = **cmd+0x748**, the same word as Start3D w18 (constant pair {0x748, 0x8c0} at kext 0x…54e8b38). RENDER.md:602 is wrong here. |
| layout.c:640 | w17 | 0x4c | "to End" | SOURCED-decompile | kext17: size of Finalize3D |
| layout.c:641 | w18 | cmd+0x8f0 | — | SOURCED-decompile | kext17 cmd+0x8f0 |
| apple.c:1008-1044 | fragment mapping (regs32 → 0xf18, 0xf80, 0xf88, —, 0x6d0, 0x618, 0x620, 0x628, 0xf38, 0x3e00, 0xfd8, 0x4070, 0x11d0..0x11f8; regs64 → 0xfa8 … 0xfd0) | — | — | SOURCED-decompile (slot → register) | fw 0xb7fc Start3D loads (RENDER.md:192-202, 605-625). Load/store bases duplicated for load and store (apple.c:1034-1037), and 0xfc0 duplicated per pipe (1031-1032): DERIVED. |

3D self-test and render-test register values (`apple.c:1494-1523`; same values in `render-test.c:241-289`):

| file:line | register | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| apple.c:1494 | 0xf18 | 0x00040004 | ISP_MTILE_SIZE | SOURCED-decompile | kext10 halComputeGeometry (RENDER.md:610) |
| apple.c:1495-1496; render-test.c:266-267 | 0xf80 / 0xf88 | 0x3f800000 / 0x300 | ISP_BGOBJDEPTH / ISP_BGOBJVALS | SOURCED-capture (values); names DERIVED | iOS 17 record body+0x4a8 (RENDER.md:611). RENDER.md:247-250 had the names shifted by one register; kext10 writes 0xf80/0xf88 from one u64 field. Render output matches iPadOS. |
| apple.c:1498 | 0x6d0 | 0x1f | — | SOURCED-decompile | kext10 3D register list constant |
| apple.c:1499-1501 | 0x618/0x620/0x628 | 0x2a40 / 0x3c040 / 0x402 | EVENT_PIXEL_PDS_CODE/DATA/INFO | SOURCED-capture | record end-of-tile pair (RENDER.md:613, 627-631). kext10 maps the same three slots. |
| apple.c:1502 | 0xf38 | 0x23000f | "ISP_CTL, process_empty_tiles" | SOURCED-decompile (0x21000f) + bit 17 `[DEBUG]` | kext10 formula 0x21000f (RENDER.md:614; render-test.c:269 uses 0x21000f). Bit 17 = Mesa `process_empty_tiles`; on A10 it had no effect (RENDER.md:659-660). Meaning unconfirmed. |
| apple.c:1503-1505 | 0x3e00 / 0xfd8 / 0x4070 | 0x408 / 4 / 0xf9 | — | SOURCED-decompile | kext10 register-list formulas (0xfd8 = bpp & 0x1f; 0x4070 = (x>>4) \| 0xf8) |
| apple.c:1506-1511 | 0x11d0..0x11f8 | tan15/64, tan60/64, 64·16 | line rasterization | SOURCED-decompile | kext10 (RENDER.md:616); scaled at apple.c:1881 |
| apple.c:1517 | 0xfa8 | 0x88 | sample positions | SOURCED-decompile | kext10 |
| apple.c:1518 | 0xf28 | 0x14 | ISP_RGN | SOURCED-decompile | kext10 (RTM+0x18 >> 2) |
| apple.c:1519-1521 | 0x6a0 / 0x6b0 / 0x6b8 | 0x26c0/0x2740, 0x3c030, 0x0080000000800000 | PDS_BGRND0/2/3 | SOURCED-capture | record background descriptor R9+0x280 (RENDER.md:228-231, 622) |
| apple.c:1522-1523 | 0x11080 ×6 | 0x1d3 | per cluster | SOURCED-decompile | kext10 formula `0x43 \| (n−1)<<7 \| x` when no per-cluster buffer (param_6+0x2b0 == 0) |
| (zero) | 0x11020 ×6, 0xfd0, 0xfb0, 0xfb8, 0xfc0, 0xf48–0xf68, 0xf30 | 0 | — | 0x11020/0xfd0 **UNKNOWN**; the rest DERIVED | zero; moving them changed nothing (driver24–29, RENDER.md:642-644). Rogue zero for no depth/stencil. |
| apple.c:1686-1701 | resize patches (R13 size/addr, R23+0x120, R24+0x63ec..) | formulas | — | SOURCED-capture | `size128x32` variant diff (RENDER.md:71, 652-663) `[DEBUG]` |
| apple.c:1902-1906 | 0xfd0 variants | 0x24000081, 0x30070 | record PDS task | SOURCED-capture `[DEBUG]` | record body+0x160/+0x168 |

### 1.12 Driver GPU pages, heaps, reserved mappings

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| apple.h:30-35 | heap bases | general 0x08_0000_0000, PDS 0x2a_…, USC 0x2c_…, RGNHDR 0x2e_f000_0000, VISTEST 0x2f_…, TRANSFER_FRAG 0x30_… | below 2^38 | SOURCED-experiment (2^38 limit); exact bases DERIVED | relocations to 0x40_… stall (`reloc3.log`, `reloc4.log`, RENDER.md:673-678). PDS/USC bases verified by UAPI tests. RGNHDR/VISTEST/TRANSFER_FRAG untested. |
| layout.h:22; apple.c:494 | GPU VA 0x200000 +0 | 0x80000000 | terminate-only stream | SOURCED-experiment | Rogue STREAM_TERMINATE (hooks 42/46; 0x40000000 is a link and faults, hooks 34/43) |
| layout.h:22; apple.c:495, 1212 | GPU VA 0x201000 | 0xd3000000 (HALT) | "HALT for the terminate and context PDS programs" | **UNKNOWN** `[PLACEHOLDER]` | provisional HALT from hook 26 (PDS HALT encoding confirmed by captures). Probably unreachable: the registers that name it are PDS-relative (§1.8). |
| layout.h:23 | GPU VA 0x203000 | flush scratch | Q → RGX 0xe240 | SOURCED-experiment | hook 46 |
| layout.h:24 | GPU VA 0x204000 | self-test output | — | SOURCED-experiment | experiments 53/68 `[DEBUG]` |
| layout.h:25 | 0x300000000 | reference code base | — | SOURCED-decompile | kext17 P+0x10/+0x18 (reference layout only) |
| apple.c:496, 1213, 1978 | PDS page +0 | 0xd3000000 | HALT | SOURCED-experiment `[PLACEHOLDER]` | hook 37 (experiment 36 fetched PDS base+0) |
| apple.c:1152-1153 | every VM: data page at 0x200000 | — | terminate/context PDS + flush scratch | SOURCED-experiment | DRIVER.md:107-108 |
| apple.c:1155 | every VM: zeroed page at VA 0 | — | end-of-render write without data | SOURCED-experiment `[PLACEHOLDER]` | driver27/28-va0.log: a 0xaa page stays unchanged and the job completes. Likely the end-of-tile image descriptor's second (zero) address (RENDER.md:638-650). iPadOS maps its code heap at 0. |
| apple.c:1167, 1218 | self-test ctx_state | 0x202000 | — | SOURCED-experiment | hook 42 |

### 1.13 Kernel self-test store job (`apple.c:500-566`) `[DEBUG]`

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| apple.c:528 | CDM record 0 | {4, 0x902, 0x3e00, 0, 0, 0, 0x40000001, 0} | binding DMA task | SOURCED-capture | iPadOS record 0 (`out/ios-capture7`, COMPUTE.md:646-659); experiment 68 |
| apple.c:529 | CDM record 1 | {0x2103, 0x800, 0x3f00, 0, 0, 0, 0x40000000, 0} | kernel | SOURCED-capture | `out/ios-capture6` (COMPUTE.md:634-640); experiment 66 |
| apple.c:530 | terminate | 0x80000000 | — | SOURCED-capture | iPadOS appends it at commit (COMPUTE.md:628-632) |
| apple.c:540-542 | argument table | {buffer, 0, 0x10001} | — | SOURCED-capture | capture7 entry {VA, CPU ptr, 0x10001} |
| apple.c:544-549 | binding data | {pds+0x1000, pds+0x1010, 0x10000002, 0x90004001} | DOUTD sources + control words | SOURCED-capture | capture7 |
| apple.c:550-552 | binding code | f0001000 f4001808 d3000000 | DOUTD ×2, HALT | SOURCED-capture | capture7 |
| apple.c:554-556 | kernel data | {0x40, 0x10, 0x80000000} | USC offset, "temps 2", DOUTW control | SOURCED-capture (values); "temps 2" DERIVED | capture6 {0x20c0, 0x10, 0x80000000, 0}. The 0x10 interpretation is Rogue's DOUTU temps field (cdm.h:183-186). |
| apple.c:557-561 | kernel code | c2c00002 d3000000 f0000a01 fc000002 d3000000 | branch, HALT, DOUTW, DOUTU, HALT | SOURCED-capture | capture6; experiment 66 |
| apple.c:515-526 | `usc_store_marker` | 33 × u16 | store 0x1357 | SOURCED-capture | see §3 |

### 1.14 Device information (`apple.c:2063-2083`)

| file:line | feature | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| apple.c:2069 | cdm_control_stream_format | 1 | — | DERIVED | Rogue/powervr choice. It selects the UAPI command-stream fields (compute-test.c:411-418). No A10 meaning. |
| apple.c:2071 | num_clusters | 6 | "CORE_ID: 6 clusters" | SOURCED-decompile | fw writes 0x11ff8 = 0..5 in StartCompute/StartTA; legacy BVNC 13.10.6.2 (N = 6). CORE_ID 0x011b0602 (`core-identity.log`). |
| apple.c:2073, 2075 | phys_bus_width, va bits | 40, 40 | — | DERIVED | Rogue MMU. Data paths are 38-bit (experiment). |
| apple.c:2077-2079 | tile size | 32 × 32 | — | SOURCED-decompile | kext10 `(w+0x1f)>>5`; kext17 FUN_fffffff006031f18 (RENDER.md:290-298) |
| apple.c:2081-2082 | isp_samples_per_pixel | 2 | "TE_AA as the iOS 10 kext sets it: 1, 5, 7 for 2, 4, 8 samples" | DERIVED | MSAA untested; only one sample has been rendered |

### 1.15 `pvr-compute-test.c` with `g9p-cdm.h`: CDM records, PDS programs, end of pass

`g9p-cdm.h` documents per-field provenance itself ("decoded + tested / observed / Rogue"). Its labels agree with this audit except where noted.

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| compute-test.c:115-126 | `usc_store_marker` | 33 × u16 | "tools/isa/g9p.py store_kernel(0x1357)" | SOURCED-capture | see §3 |
| compute-test.c:201-202; cdm.h:72, 75, 80 | kernel K0 | 0x2103 (one thread), 0x2107 (GRID) | fence \| any cluster \| data blocks \| 0x2100 | value SOURCED-capture | capture6 (0x2103). DATA_BLOCKS ≥ 1 needed past dword 3 (COMPUTE.md:817-818). Bit 0 fence tested. **Bit 1 "any cluster" is a Rogue name** (COMPUTE.md:851-853, DERIVED). **0x2100 meaning UNKNOWN** (cdm.h:77-80). |
| compute-test.c:205; cdm.h:125-131 | binding record | {4, 0x902, 0x3e00, 0, 0, 0, 0x40000001, 0} | DMA task, 2 blocks, all clusters | SOURCED-capture | capture7. K1 low bit 2 observed. **w6 bit 0 meaning UNKNOWN** (cdm.h:121-123). iPadOS uses K0 = 6 (any cluster) for its own DMA tasks. |
| compute-test.c:212; cdm.h:111-118 | one-thread kernel | {K0, 0x800, 0x3f00, 0, 0, 0, 0x40000000, 0} | — | SOURCED-capture | capture6; experiment 66 |
| compute-test.c:209-210; cdm.h:140-148 | GRID kernel w3–w5, w6, w7 | groups−1; (threads%32)<<27 \| 1; (threads−1)<<20 | workgroups, TG allocation, group size | SOURCED-experiment | COMPUTE.md:793-840. **w6 rule conflicts with iPadOS** (1 for 8 threads, 0x40000000 for one thread; COMPUTE.md:859-862). |
| compute-test.c:233-235 | argument table +0x10 | threads \| threads<<16 | thread count | SOURCED-experiment | COMPUTE.md:760-764, 770-773 |
| compute-test.c:236-238, 244-245 | binding data | {pds+0x1000, pds+0x1010, 0x10000002, 0x90004001} | — | SOURCED-capture | capture7 |
| compute-test.c:246-248; cdm.h:47-57 | binding code | DOUTD q0 ctrl 4; DOUTD q1 ctrl 6 END; HALT (= f0001000 f4001808 d3000000) | — | SOURCED-capture | encoding fields SOURCED-experiment (COMPUTE.md:824-829) |
| compute-test.c:256-259; cdm.h:187-191 | kernel data | {usc_at, 0x10, 0x80000000} | USC offset, 0x10, DOUTW control | SOURCED-capture | 0x10 as "2 temp blocks" is Rogue (DERIVED) |
| compute-test.c:261, 271-275 | kernel PDS (one thread) | c2c00002 d3000000 f0000a01 fc000002 d3000000 | — | SOURCED-capture | experiment 66 |
| compute-test.c:261-270 | GRID PDS | c2c00004 f4001201 d3000000 d3000000 f0000a01 fc000002 d3000000; ctrl dword 4 = 0x90000000 | IF1 writes workgroup ID | SOURCED-experiment | COMPUTE.md:805-816. Mechanism matches Metal `PDSEncoderGen1::EncodeComputePDSProgram` (0x21c7bda9c; COMPUTE.md:891-895). |
| cdm.h:34, 40 | END bit 26, CC bit 27 | — | — | END SOURCED-experiment; CC SOURCED-capture (observed), meaning DERIVED | COMPUTE.md:601-605 |
| cdm.h:64-67 | BRA !IF1 | 0xc2c00000 \| target | — | SOURCED-capture | absolute vs relative target open (Mesa disassembles it as relative +2) |
| cdm.h:86-87 | K0 bits 30–31 | 2 = terminate, 3 = fence block | — | SOURCED-capture + experiment | terminate = Rogue 0x80000000 (experiment 46); 0xc0000003 from iPadOS's tail (COMPUTE.md:855-857, 908-911) |
| compute-test.c:306-320; cdm.h:218-235 | end-of-pass tail | {2, kick_data\|2, kick_code, 0, 0, 0, 0x40000000, 0}, {0xc0000003, fence_data\|4, fence_code, …}, {3, kick_data\|4, kick_code, …}, {0xc0000003, fence_data\|4, …}, 0x80000000 | iPadOS barrier | SOURCED-decompile (structure) + SOURCED-experiment | Metal `ComputeContext::encodeBarrier` / `endComputePass` (0x21c7acac4, 0x21c7abf2c); internal-record template 0x21c877eb0 (COMPUTE.md:876-889). TAIL_APPLE_K1=0xf: 400 jobs pass (COMPUTE.md:1034-1056). |
| compute-test.c:135-138, 321-341 | tail K1 flags + fence data | barrier \|2, others \|4; fence data at 0x2700 (zero) | default combination | DERIVED | the tested pairings were (barrier \|2, fence-block data = kick data 0x2000) and (barrier \|0xa, zeroed fence data). The current default (\|2 with zeroed data) mixes the two. |
| cdm.h:174-180 | fence program | c2c00002 d3000000 f0000005 d3000000 | DOUTC | SOURCED-capture | internal heap region `out/ios-capture7/iocalls/call_000_regions/r_005d5fb0000.bin` +0x200 (also capture6 r_00aa08d8000.bin) |
| cdm.h:165-171 | kick program | c2c00002 d3000000 fc000002 d3000000 | kick internal kernel | SOURCED-capture | same region +0x100 (verified in this audit) |
| cdm.h:199-209 | empty USC kernel | 0100 0140 0000, c000 ×29, 8000 | driver shader 39 | SOURCED-capture | same region +0x40; metal-tt empty kernel (COMPUTE.md:565-568) |
| compute-test.c:358-385 | flush record (TAIL_APPLE_FLUSH) | K0 4, K1 \|0xa; code f0000800 f4000012 d3000000; data {addr, 0x90000004, 0, usc, 0x10}; constants 0 | iPadOS first tail record | SOURCED-capture `[DEBUG]` | `out/ios-grid2`; same region +0x340; Metal `EncodeShaderConstantsPDSProgram` (COMPUTE.md:994-1002). No effect alone. |
| compute-test.c:344-357 | SPIN_USC (shader 38 `c401`) | file | fenced kernel | SOURCED-capture `[DEBUG]` | `out/ios-grid2` R7. **Hangs the GPU on Linux** (COMPUTE.md:1004-1032). |
| compute-test.c:221-225 | BO layout | PDS heap +0, USC heap +0, general +0x10000/+0x14000/+0x18000 | — | DERIVED | test choice (the CDM state buffer gets 16 KiB, size need UNKNOWN) |

### 1.16 `pvr-render-test.c`

| file:line | location / field | value | meaning as stated | class | source |
|---|---|---|---|---|---|
| render-test.c:35-42 | capture addresses | IOS_DATA 0x1_00000000, record 0x2_00004000, stream 0x1_00040000, images 0x1_00064000, target 0x1_00014000 | — | SOURCED-capture | RENDER.md:158-188 address table |
| render-test.c:36, 43-44 | RELOC, RT, FL_PAGES | general − 0x1_00000000; general + 0x2_00000000; 1024 | — | DERIVED | stays below 2^38 |
| render-test.c:112-156 | relocation rules | VDM words (bits 32–39 low byte, then bits 0–31); image descriptors (addr>>1, bit 63); PDS DMA words | — | DERIVED | Mesa vdm.xml word layout plus capture R13 (RENDER.md:627-631) |
| render-test.c:210 | EXTHDR_APPLE | 1<<29 \| 1 | Apple stream extension | — (Linux UAPI, driver-defined) | — |
| render-test.c:224-225 | ppp_ctrl / te_psg | 2 / 0x20000 | "complete on terminate" | SOURCED-decompile | kext10 constants. The TE_PSG bit name is Rogue. |
| render-test.c:230 | 0xc90 | 0x1e3ce508 | PDS_CTRL | SOURCED-decompile | kext10 |
| render-test.c:214-218, 231-236 | ctx state, VDM store/resume tasks, 0x470 = 0x640, 0x418 = 0, 0xf058..0xf070 (0xf038/0xf040 = 0) | record values | — | SOURCED-capture | R9+0x28 body (RENDER.md:525-536) |
| render-test.c:219, 237 | 0x11030 ×6 | 0 | per cluster | DERIVED | record +0xa0/+0xa8 maps onto this list. The value used is zero, not checked against the capture. |
| render-test.c:238 | 0xc78 | 0x88 | — | SOURCED-decompile | kext10 |
| render-test.c:266-273 | bgobjdepth, bgobjvals, isp_ctl, pds_info, pds_data | 0x3f800000, 0x300, 0x21000f, 0x402, 0x3c040 | — | capture / kext10 | as §1.11 |
| render-test.c:245-252, 277-288 | Apple extension (3D) | as §1.11 | — | as §1.11 | — |
| render-test.c:374, 387 | HWRT args | tpc_stride 1, region header size | — | DERIVED | powervr UAPI |
| render-test.c:433 | PASS criterion | 3584 clear + 512 triangle pixels | matches iPadOS | SOURCED-capture | iPadOS `late.bin` R4 (RENDER.md:573-577) |

### 1.17 `pvr_apple_queue.c`

The values `credit_limit 64`, `hang_limit 1`, timeout 5 s and `num_rqs 1` are drm_sched plumbing with no hardware meaning. The engine scheduling depth is actually bounded by `APPLE_JOB_SLOTS` (apple.c:137, 16, DERIVED, matching layout.c:94).

---

## 2. Ranked UNKNOWN, placeholder and mismatch items (highest risk first)

1. **The power-state struct overlaps the whole TA queue area** (`layout.c:210` vs `layout.c:50-65`).
   - X+0x301 → fw VA 0x130000 = heap 0x30000 = `HEAP_TA_RING`. The firmware's power struct is ≥0x4314 bytes.
   - The firmware writes +0x10, +0x38, +0x1c0, +0x1088, +0x41f4, +0x4218, +0x4240, +0x42f0 and +0x4310. On device it wrote heap 0x30010 = 4 and 0x30038 = 1 (`heap-compute.bin`); in `heap9.bin`, 0x30010 holds the driver's TA entry instead.
   - Those offsets are TA ring entry 0's command-ring head/slot, entry 2's head, entry 22's queue pointer, entry 211's engine and TA pool entries ~104–111.
   - The firmware also reads +0x38 as "GPU powered", and `write_ta_job` transiently zeroes it.
   - **Source/fix:** give the power struct its own ≥5 pages (or move the TA objects out of heap 0x30000–0x34400). Re-run the 300-render / 300-compute interleave and diff heap 0x30000–0x34400 against what the driver wrote.
   - Read fw users of `[X+0x301]` (FUN_00006a98, FUN_00007de0, FUN_0000838a) to size the struct exactly.
2. **The 3D unit-state pointer uses the TA array** (`layout.c:580, 614, 634`).
   - Start3D w4 and Finalize3D w7 = X+0x134 page + 8, but fw 0x54ec uses X+0x138 + 8 for the fragment engine (stride 0x28). kext17 also passes a separate global.
   - The driver's pointer overlaps TA unit 0's status at +8, which the firmware polls.
   - **Source/fix:** read fw 0x54ec and the status checks in FUN_00003b0c / FUN_00004f3c. Set w4/w7 = `fw_va(0x1d000) + 8` and re-run the render matrix.
3. **The compute context-store path is unpopulated** (`layout.c:308-328`).
   - FinalizeCompute w9 (skip) = 0 (kext17: 0x30), w11 = 0 (kext17: cmd+0x2ac; fw writes through it when RGX 0x4a0 bit 1 is set) and w4 = 0 (kext17: cmd+0x1f0).
   - StartCompute w11 points every job at one shared context page; kext17 uses per-command cmd+0x1f0, and a non-zero ctx[0] switches later jobs to resume.
   - **Source/fix:** read fw case 0xc and fw 0xd7c0 / 0x16176 (resume). Mirror kext17's offsets in the per-job slot. A context store can be provoked by a long kernel plus a second queue or a firmware preemption request (a "context store" control-ring opcode; decode the control-ring opcodes 3..31 at fw 0x20904).
4. **The CDM terminate / context-store PDS programs are placeholders** (`layout.c:297-298, 350-351`; `apple.c:495`).
   - 0x201000/0x201010 in RGX 0x4b8 and 0x4a8 are, by Rogue semantics and the A10 PDS-relative addressing (experiments 49/67), at PDS base+0x201000, i.e. userspace PDS heap memory, not the HALT at GPU VA 0x201000. They have never been shown to execute.
   - **Source:** Metal `AGX::G9::ContextSwitcher::setupComputeCommand` (0x21c76c83c) and `PDSEncoderGen1::EncodeContextSwitchPDSProgram` (0x21c7bdd18, in `S/agxm/pds.c`); kext10 generateRegisterList (0x4b8/0x4c0 from descriptor+0xd8/+0xe0).
   - **Experiment:** put an unmapped PDS-relative offset (e.g. 0x3f0000) into 0x4b8/0x4a8 and force a context store; the fault address tells whether they are absolute or PDS-relative.
5. **I/O entries 1, 2, 4, 5, 6 are RAM** (`layout.c:226-229`).
   - On iOS these are the AIC timer (0x20e101000), AIC software interrupt, display-underrun workaround (0x200800000) and temperature sensor (0x20e0c0020).
   - Firmware-to-AP interrupts (likely via AICSWInt) and timer reads are silently absorbed. This plausibly explains "no completion message" (DRIVER.md:115).
   - **Source:** kext17 `configureDevice` (0x…5ff2818..3d6c, `this+0x4490` for AICSWInt), FENDER.md §1.2.
   - **Experiment:** map entry 1 (AIC timer) for real, then entry 2 with the AIC IRQ wired, and watch for an AP interrupt on completion.
6. **The firmware power path is bypassed**. P+0x93c / P+0x944 are left 0 (kext17: P+0x93c from a global bit, P+0x944 = 1), so fw 0x6b12 only sets a software "powered" flag (into the TA ring, item 1). The AP powers Fender directly and runtime PM is forbidden. **Source:** kext17 0x…6012cec..2d14 and the global 0x…b3686a. **Experiment:** set P+0x944 = 1 and P+0x93c per kext, drop the AP-side request and check the firmware's own power-up (fw 0x16d40).
7. **The init-sequence program is empty** (`layout.c:359`). iOS emits RGX 0xe140/0xe148 (MMU context) and 0xe160 (time) (kext17 0x…6021d10, +0x708/+0x710). The driver writes 0xe140/0xe148 itself but never 0xe160, so GPU timestamps and timeouts based on it are unvalidated. **Source:** kext17 0x…6032568 (+0x710). **Experiment:** add the type-1/3 entries and compare firmware trace timestamps.
8. **The free-list descriptor is partially filled** (`layout.c:471-477`).
   - +0x28 = pages/32 has no source.
   - +0x0c, +0x34, +0x44, +0x64, +0x68 and +0x6c are left zero (kext17 fills them).
   - The stack is pre-filled instead of grown, and the TA wait includes PM_OUT_OF_MEMORY, so an out-of-memory scene silently "completes".
   - **Source:** kext17 `FUN_fffffff006040ba8` and fw 0x16634 / the PM growth path. **Experiment:** a scene larger than the 4 MiB parameter buffer.
9. **P+0x00 / +0x08 / +0x20 fixed windows** (0x600000000, 0xffc00000, 0x1ffff8000) are kext constants of unknown meaning. The driver moved its code bases to 0x2a/0x2c_0000_0000 and heaps elsewhere. **Source:** fw readers of `[[0x8e54c]]+0x0..0x24` and their shared-page copies; kext17 0x…6012bd0. **Experiment:** vary each one in turn and look for faults.
10. **The Finalize3D w13 pointer differs from iOS** (`layout.c:639`): cmd+0x8c0 instead of kext17's cmd+0x748 (= Start3D w18). RENDER.md:602 should be corrected. **Fix:** point w13 at the same word as Start3D w18 (`sc+F_WAIT`), then run the render matrix.
11. **The compute scheduling token is the full seq** (`layout.c:337`) while TA/3D use `seq & 0xff`. Bits 8–14 select the pool entry, so compute walks pool entries 1..127 after job 255. **Source:** fw 0xe184 and the pool consumer.
12. **The cancel thresholds are self-made** (`layout.c:317, 346, 463-464, 589-590`). Compute uses a global {1, 0} against {0, 0}; TA/3D use {~0, ~0}. iOS compares cmd+4 with context buffer+0x6c. If the firmware updates the threshold (cancel/abort), shared globals affect every job. **Source:** fw cases 5/7/0xb and the writers of +0x6c.
13. **CDM per-cluster 0x11040 and TERMINATE_PDS1 (0x4c0) are zero** (CDM args +0x18..+0x47 and HEAP_CDM_REGS). This is correct while kernels need no per-cluster buffer (kext10). Once kernels need scratch or spill memory, 0x11040 must carry `base + i·stride | 1`. **Source:** kext10 `AGXCLChannelG9G::generateRegisterList` and the descriptor's +0x120/+0x128 origin.
14. **The TA self-test "empty" job uses the superseded register mapping** (`apple.c:1415, 1420-1421`): 0xc90 = 0x640, 0x428 = store task 0, 0xcc0 = 0x900, with stale comments. Debug only; fix or delete.
15. **U[0] = 3** (`layout.c:387`) enables firmware debug/trace event writes in every build `[DEBUG]`. The always-used trace ring is required anyway; SKU ring writes are not. Decide on 0 for production after re-running the 700-job test.
16. **The kick omits ring bits** (`apple.c:53`). iOS sends `(ring & 7) << 2`. Decode the EP 0x21 payload handling (fw ~0x1c9e2–0x1cbf6) and the event table at fw 0x2e7e8.
17. **The VA-0 zero page and the data-page HALT are placeholders** (`apple.c:495, 1155`). Identify the end-of-render zero write (image descriptor word 3 at R13+0x58) and give the descriptor a real or valid null address. Then retry without VA 0.
18. **Work entry +0x13, X+0xe4/+0xe8/+0x140 and FL +0x28 have no known meaning**. Read the fw consumers at 0x20788 (`0xdac6(queue, entry[0x12], …)`) and 0x1ba3a.
19. **ISP_CTL bit 17 and 0x11020/0xfd0 = 0** in the 3D self-test (`apple.c:1502`). Bit 17 has no measured effect. Drop it or source it from kext10's ISP_CTL formula.
20. **CDM K0 0x2100 bits, the binding w6 bit 0, K0 bit 1 ("any cluster") and the word-6 rule vs iPadOS** (cdm.h:72-80, 121-123, 133-139). Read Metal `executeKernelInternal` / `performEnqueueKernel` (0x21c7acc10, 0x21c7ab2c4 in `S/agxm/pds.c`) for how iPadOS composes K0 and words 6/7.

---

## 3. Embedded binary sequences

| Where | Content | Apple-generated? | Evidence |
|---|---|---|---|
| `apple.c:515-526` `usc_store_marker` (u16 ×33) and `compute-test.c:115-126` (same words) | USC `store_marker` kernel: out[0] = 0x1357 | **Yes**: metal-tt `applegpu_g9p` output, byte-identical to iPadOS's loaded code | It occurs at +0x20c0 in `G/out/ios-capture6/iocalls/call_000_regions/r_00ad2d1c000.bin` (and 53 more capture files, e.g. `ios-capture7/.../r_005d5fa0000.bin`). `tools/isa/g9p.py store_kernel(0x1357)` also emits exactly these 33 words (checked in this audit). The new code comments credit g9p.py, which reproduces the capture. The earlier u32 form ended with an extra `0000` halfword. |
| `cdm.h:199-209` `g9p_usc_empty_kernel` | `0100 0140 0000`, `c000`×29, `8000` | Yes (form) | internal heap `ios-capture7/.../r_005d5fb0000.bin` +0x40; metal-tt empty kernel (COMPUTE.md:565-568) |
| `apple.c:550-561`, `compute-test.c:246-275`, `cdm.h:165-180` | PDS binding / kernel / kick / fence programs | Yes (captured) | binding and kernel: capture6/7. Kick +0x100, fence +0x200 and flush +0x340 in `r_005d5fb0000.bin` (checked in this audit). |
| `compute-test.c:261-270` | GRID PDS (c2c00004 f4001201 …) | No: our own, Rogue-style | same mechanism as Metal `EncodeComputePDSProgram` (COMPUTE.md:891-895) |
| `compute-test.c:380-382` | flush record PDS f0000800 f4000012 d3000000 | Yes | `r_005d5fb0000.bin` +0x340; `out/ios-grid2` |
| `SPIN_USC` / `TAIL_APPLE_FLUSH` files (`shader38.bin`, `flush37.bin`) | `c401` fenced kernel; `c310` flush kernel | Yes (captured, Apple driver shaders 38/37) | `out/ios-grid2` (COMPUTE.md:954-1002). Test inputs only; `c401` hangs on Linux. |
| `apple.c:494-496`, layout.c:265-267 | 0x80000000 terminate, 0xd3000000 HALT | No: Rogue encodings (HALT also appears in every captured PDS program) | experiments 42/46/37 |
| `apple.c:1779-1784` | PPP terminate state 0x02000000 0x00040001 0 + 0xc0000000 | Yes (captured stream end) | `out/ios-render1/.../r_008c40d4000.bin` +0x11c and all render variants |
| `apple/gpu-tri.bin` (loaded at `apple.c:1544`, `render-test.c:331`) | 32 captured regions: USC/PDS code heap, VDM stream, PPP state, image descriptors, record | Yes (capture) | built by `tools/tri-blob.py` from `out/ios-render/base`. It contains Apple code and Metal state, so treat it as a redistributable-content question. |
| `apple.c:1442-1457`, `1494-1523`; `render-test.c:214-288` | register/record words | Mixed: record words captured, others kext10 formulas | §1.10-1.11 |

---

## 4. Counts

There are 291 table rows in §1; one row may cover several literals. Each row is counted once, under the first class named in its class cell. Three rows are references or plumbing ("as §1.11", "capture / kext10", the UAPI extension header).

| Primary class | Rows |
|---|---|
| SOURCED-decompile | 129 |
| SOURCED-experiment | 64 |
| DERIVED | 47 |
| SOURCED-capture | 34 |
| UNKNOWN | 14 |

21 rows have an UNKNOWN component: either the value is unknown, or the value is sourced but its meaning is not (e.g. P+0x00/0x08/0x20, X+0xe4/0xe8/0x140).

Tags, counted per row:

| Tag | Rows | Note |
|---|---|---|
| `[PLACEHOLDER]` | 7 | |
| `[DEBUG]` | 9 | §1.13 and the TA self-test subtable are debug-only as a whole |
| `[MISMATCH-iOS]` | 6 | |
| `[STALE-COMMENT]` | 4 | |
| `[CONFLICT]` | 2 | the power-state struct / TA area overlap, counted from both sides |
