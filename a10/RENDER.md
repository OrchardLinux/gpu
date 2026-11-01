# Render path: first capture (2026-10-29)

Captured on iPadOS 17.7.11 under palera1n with `ios-capture/` (`gpu-capture
--render`): one constant-colour triangle into a 64×64 BGRA8 texture, with GPU
memory snapshotted inside the submit trap. Raw data: `out/ios-render1/`
(git-ignored). Compute findings: [COMPUTE.md](COMPUTE.md). Driver-stack
comparison: [REFERENCE.md](REFERENCE.md).

## What is established

- **One submit:** a single `iokit_user_client_trap` (index 0, 0x38-byte record)
  carries the whole render pass, as for compute. The capture tool died after
  the submit (the earlier SIGILL); the snapshot was saved first.
- **Shaders:** `tri_vs` and `tri_fs` as loaded by iPadOS are byte-identical to
  `metal-tt -arch applegpu_g9p` output (`ios-capture/offline/tri.*`): fragment
  at code-heap +0x40, vertex at +0x2c0. The offline compiler covers render
  shaders too.
- **PDS programs are Rogue:**
  - vertex-input DMA (`f0002000 f0002808 f0003010 f4003818`);
  - USC kicks (`f0000a01 fc000002`) and further DOUT forms (`fc00000a`,
    `f4000012`, `f0000800`), probably coefficient and iterator setup;
  - Rogue load/store/immediate sequences in `r_008c4014000` (`d1800002`,
    `d0800004`, `d1000000` WDF, `f000282b`), the shape of Mesa's
    `pvr_pds_generate_common_ld_st`.

## Regions to decode (driver phase)

| Region | Contents (first reading) |
|---|---|
| `r_008c3f94000` | Code heap: USC shaders and PDS programs (PDS exec base). |
| `r_008c3ff4000` | Likely VDM control stream: block-typed words (`0x8…`, `0x2…`, `0x4…`, `0x6…`), PDS state and links. Compare with Mesa `csbgen/rogue/vdm.xml`. |
| `r_008c40d4000` | Repeated per-draw state words, likely PPP/ISP state. Compare with `ppp.xml`/`ipf.xml`. |
| `r_008c4014000` | PDS load/store programs and their data. |
| `r_008c3fe8000`, `r_008c3fec000`, `r_008c3ff0000` | Register-style setup lists (address/value pairs `0x0014xxxx`, `0x0003c0xx`), probably render-target and tiling configuration. |
| `r_008c4024000`, `r_008c40e4000` | Large, zero at submit: parameter buffer and render target candidates. |

## Variant captures (2026-10-30)

`ios-capture/session.py render` captures eight variants of the triangle, each
changing one parameter (`capture.m` `kVariants`): `base`, `base2` (repeat),
`verts6`, `draws2`, `size128x32`, `clear`, `load`, `color`. Raw data:
`out/ios-render/<variant>/` (git-ignored). `tools/render-diff.py` pairs the 26
regions by order (the layout is identical in every run) and diffs them.
`base2` against `base` differs in only 5 words (counters/stamps).

**The control stream is plain Rogue VDM** (Mesa `csbgen/rogue/vdm.xml`).
`tools/vdm-decode.py REGION GPU_BASE` follows it. In `base`, R10 is the stream
at GPU 0x1_00040000:

```
+0x0000 STREAM_LINK -> 0x1000400dc      (older encoders' blocks skipped)
+0x00dc STREAM_LINK -> 0x1000401b8
+0x01b8 VDM_STATE  vs_pds_code=0x480 vs_output=4x4 usc_unified=4x16 temps=2x16 data=1x16
+0x01c8 PPP_STATE  4 words at 0x100000de0
+0x01d0 PDS_STATE  dm=VDM usc_common=2x64 data=1x16 data_addr=0x302c0 code_addr=0x400
+0x01dc VDM_STATE  vs_pds_data=0x302d0
+0x01e4 PPP_STATE  6 words at 0x100000020
+0x01ec..0x0214 PPP_STATE x5 (R8, R24, R17)
+0x021c INDEX_LIST TRI_LIST B32 count=3 instances=0 offset=0 split_count=170
+0x0230 PPP_STATE  3 words at 0x10013c11c
+0x0238 STREAM_TERMINATE
```

What each variant changes:

| Variant | Words that change | Meaning |
|---|---|---|
| `verts6` | R10+0x220: 3 → 6 | `INDEX_LIST2.index_count` |
| `draws2` | R10+0x230..: one more `INDEX_LIST` (`6e440600 3 0 0 aa`) before the final PPP state and `STREAM_TERMINATE` | one block per draw |
| `clear` | R13+0x48..0x54: (0,0,0,1) → (1,0.5,0.25,0.125) floats, R,G,B,A | clear colour |
| `size128x32` | R9+0x6a0/0x6a4: 64,64 → 128,32; R24+0x63f4..: viewport floats 32,32,32,−32 → 64,64,16,−16; R13 `0x7e01` → `0x3e03` (×4); R23+0x120 `0x40001` → `0xc0000`; R24+0x63ec `80000001 1` → `80000003 0` | width/height, viewport (PPP), size-derived configuration (likely tile counts) |
| `load` | R2 (code heap): PDS programs change | background object that loads the old target |
| `color` | R2+0x44..0x60 (fragment USC code) | the colour is a shader constant |

**GPU addresses** (superseded by the ground-truth table below). Regions have their own GPU bases; CPU − GPU is not constant
(R10: GPU 0x1_00040000; R24: GPU 0x1_00148000). Assuming size-aligned bases,
the PPP targets resolve by content: R8 (16 KiB) is a state buffer at GPU
0x1_0013c000 (five of the PPP blocks), and R24+0x63e8 is the 9-word viewport
block (header, then scale/offset floats, depth 0..1). PDS addresses in the
stream are offsets from the PDS heap (code 0x400, VS code 0x480).

## Firmware microsequence opcodes for render (static)

The interpreter (fw 0x9f04) dispatches through a `TBH` table at 0xa3dc with 15
opcodes. Handlers: 0→0xa3fa, 1→0xd2c8, 2→0xcff8, 3→0xa462, 4→0xa792,
5→0xa88c, 6→0xad10, 7→0xadb2, 8→0xa4c6, 9→0xaed0, 0xa→0xa54e, 0xb→0xa61c,
0xc→0xaf6a, 0xd→0xd0d6, 0xe→0xd11e. `tools/regflow.py` lists which argument
words a handler writes to which RGX registers (straight-line flow). It
reproduces StartCompute (block +0x10 → RGX+0x480).

The core's register map is standard Rogue (kernel `pvr_rogue_cr_defs.h`):
StartCompute writes `CDM_CONTEXT_PDS0/1` and `CDM_TERMINATE_PDS/PDS1`
(0x4a8–0x4c0).

| Opcode | Evidence | Reading |
|---|---|---|
| 0 | known | wait |
| 2 | known | end |
| 0xb / 0xc | known | StartCompute / FinalizeCompute |
| 5 | 362 instructions; copies a host register block to RGX 0xc00–0xd20 and 0x428–0x464 (`VDM_CONTEXT_STORE_TASK0–2`, `VDM_CONTEXT_RESUME_TASK0–2`); byte store to 0xf078 (`CONTEXT_MAPPING0`); unit-status bytes 0x136c/0x136d beside StartCompute's 0x136e/0x136f | StartTA (geometry) |
| 1 | copies a host table to RGX+0x3a00 (`ISP_XTP_RESUME0`…, IMG `rgx_cr_defs_km.h`), writes 0x298 and 0x1c8, sets bit 4 of `ISP_RENDER` (0xf08) | 3D context resume (Start3D is 7, see the kext builders below) |

StartTA argument layout (`tools/regflow.py`): `arg+0` points to eight 32-bit
values for RGX 0xc78, 0xc88, 0xc98, 0xc18, 0xc08, 0xc10, 0xc20, 0xc28.
`arg+4` points to 64-bit values: +0x00 0xc90, +0x08 0xc38, +0x10 0xc40,
+0x18 0xc00, +0x20 0xc80, +0x28 0x428, +0x30 0xcc0, +0x38..+0x60
`VDM_CONTEXT_STORE_TASK0–2` / `RESUME_TASK0–2`, +0x68 0x470, +0x70 0x418,
+0x78 0x408. Then 0x400 is written (the kick, by analogy with 0x478 for
compute). IMG's public headers do not name 0x400–0x428 and 0xc00–0xd20
(PM/TE/VDM control); their values have to come from the kext that fills them.

The iPadOS AGX kext builds these sequences (`AGXTAChannelG9P`,
`AGX3DChannelG9P`, `agxk_ta_command.cpp`,
`agxk_render_hardware_kernel_command.cpp` in the kernelcache).

## The iPadOS kext's microsequence builders (2026-10-30)

Source: iPadOS 17.7.11 (21H461) kernelcache for iPad7,5 (`ipsw download ipsw
--device iPad7,5 --latest --kernel`). `tools/kc-kext-elf.py` wraps the
`com.apple.AGXG9P` kext (header VA 0xfffffff0054e8280, code 0xfffffff005fec000,
0x67834 bytes) in an ELF. Ghidra 12.2 headless decompiles it (1087 functions),
with an arm64 build of the decompiler. Its Makefile hardcodes `-arch x86_64` on
macOS; build with `make ghidra_opt sleigh_opt ARCH_TYPE="-arch arm64"`.
`tools/kc-xref.py` finds string references in the kernelcache.

All builders append ops through a cursor at `channel[0x17] + 0x68`. Ops with
bit 31 set (`0x8…0004`, `0x9…0004`, `0x1…0004`) are 4-word timestamp/trace
ops, emitted only when tracing is on.

| Builder (vtable slot) | Ops |
|---|---|
| Compute `FUN_fffffff006035960` (+0x168) | `0xb` StartCompute (0x12 words), waits (`FUN_…9284`), `0xc` FinalizeCompute (0xc words); `FUN_…91a8` closes the sequence and returns its firmware address, stored at command+0x1e8 with the size at +0x1ec. This matches the driver's layout. |
| TA `FUN_fffffff006035fa4` (+0x178) | `5` StartTA (0x1a words), `4` (4 words), `6` FinalizeTA (0xf words) |
| 3D `FUN_fffffff006033898` (+0x170) | `7` Start3D (0x1d words), `8` Finalize3D (0x13 words) |
| `FUN_fffffff005ffec00`, `FUN_fffffff006001398` | `0xe` (4 words), `0xd` (2 words) |

So **Start3D is opcode 7**, not 1. Opcode 1 (loads `ISP_XTP_RESUME*`) is
probably 3D context resume. The builders are called as
`builder(channel, cmd, …, cmd[3], …)`. `cmd[3]` is the hardware command
buffer; the firmware addresses in the ops are offsets into it (constants at
kext 0xfffffff0054e8b28…8b80):

| Op | Word 1 (`arg+0`) | Word 2 (`arg+4`) | Other words |
|---|---|---|---|
| StartCompute | +0x18 | +0x68 | |
| StartTA | +0x3b4 | +0x30 (64-bit register block, see above) | word 7 = +0x538 |
| Start3D | +0x3b0 | +0x68 | words 5/6 = +0x860/+0x864, word 7 = +0x890, word 9 = buffer base, words 0x12/0x13 = +0x748/+0x8c0 |

**The hardware command buffers come from userspace.** In the `base` capture,
R9 (16 KiB) holds the VDM stream base 0x1_00040000 at +0x28, and its
render-target size at +0x6a0/+0x6a4 (inside Start3D's range). Read through
StartTA's layout, R9+0x30 gives 0xc90 = 0x640; 0xc38/0xc40/0xc00/0xc80 =
0x1_00148020/24/28/2c; 0x428 = 0x0003000524001002; 0xcc0 = 0x900; then
PDS-like pairs for `VDM_CONTEXT_STORE/RESUME_TASK*`. Open: whether R9 is the TA
or the 3D buffer (the ranges overlap, so they are probably separate buffers),
and which region holds the other.

## GPU address of every region (ground truth, 2026-10-30)

`capture.m` now logs IOKit calls from device creation on (re-enabled
`IOConnectCallMethod`/`IOConnectCallAsyncMethod` entry hooks; patching
`mach_msg` crashed the process). Selector 9 on the IOGPU connection creates a
resource. Its 80-byte reply holds the GPU address at +0x00, the CPU address at
+0x08 and the size at +0x20. Selector 13 (scalars 0x4000, 0 or 1) returns a
16-byte {CPU, GPU} pair. Capture `out/ios-render/alloc-base` (identical to
`base` except counters):

| Region | GPU | Region | GPU |
|---|---|---|---|
| R2 (code heap) | 0x0 | R14 | 0x30000 |
| R3 | 0x1_00000000 | R15 | 0x3c000 |
| R4 | 0x1_00014000 | R16 | 0x1_00070000 |
| R5 | 0x1_0001c000 | R17 | 0x1_000f4000 |
| R6 | 0x14000 | R18 | 0x1_00100000 |
| R7 | 0x28000 | R19 | 0x1_0010c000 |
| R8 (selector 13, 0) | 0x1_00004000 | R20 | 0x1_00118000 |
| R9 (selector 13, 1) | **0x2_00004000** | R21 | 0x1_00124000 |
| R10 (VDM stream) | 0x1_00040000 | R22 | 0x1_00130000 |
| R11 | 0x1_0004c000 | R23 | 0x1_0013c000 |
| R12 | 0x1_00058000 | R24 | 0x1_00148000 |
| R13 | 0x1_00064000 | R25 | 0x1_00154000 |

R0 and R1 were allocated before logging started. Corrections to the earlier
alignment guess: the five PPP blocks at 0x1_0013c0xx are in **R23**, not R8;
0x1_00000020 and 0x1_00000de0 are in R3; 0x1_000f4000 is R17+0. The address
layout is deterministic between runs, so this table applies to all variants.
R9, the hardware-command candidate, lives in its own 0x2_xxxxxxxx window,
created by selector 13 with argument 1.

## Start3D register loads and where the commands live (2026-10-30)

Start3D (opcode 7, fw 0xadb2) advances its argument pointer by 4, then on the
normal path (fw 0xb7fc) loads (`tools/regflow.py`):

- `arg+0` (command+0x3b0), 32-bit: +0x00 0xf18, +0x04 0xf80, +0x08 0xf88,
  +0x10 0x6d0, +0x14 0x618, +0x18 0x620, +0x1c 0x628, +0x20 0xf38
  (`ISP_CTL`), +0x28 0xfd8.
- `arg+4` (command+0x68), 64-bit: +0x00 0xfa8, +0x08 0xfb0, +0x10 0xfb8,
  +0x18/+0x20 0xfc0, +0x28 0xf48, +0x30 0xf50, +0x38 0xf58, +0x40 0xf60,
  +0x48 0xf68, +0x50 0xf28, +0x58 0x6a0, +0x60 0x6a8, +0x68 0x6b0,
  +0x70 0x6b8, +0x78 0xf30, +0xe0 0xfd0.
- then `ISP_RENDER` (0xf08) and 0xf00 (likely the kick).

R9 is zero where Start3D's 32-bit block would be (`ISP_CTL` cannot be 0),
so **R9 is the TA command**, and the 3D command is elsewhere. The submit
record (`{0x1_00000002, 0, ptr, ptr, …}`) and two levels of what it points to
(capture `out/ios-render/tree-base`, `call_040_pre_arg2*`) are Metal
userspace objects. They reference R10, R24, R25 and the code heaps by address
but not R9, so commands are probably named by resource ID. R0/R1 were
allocated before logging started and are the remaining candidates for the 3D
command.

## Command records and the 3D block (2026-10-30, in progress)

- The kext parses userspace command records from a stream (`{start, end,
  cursor}`) and keeps the record's address as the descriptor's buffer
  (`cmd[3]`). The firmware reads the TA record in place. Record parsers by size:
  0x40 (`FUN_…478dc`), 0x1d0 (`FUN_…0cd14`), 0x3d8 (`FUN_…10638`), 0x808
  (`FUN_…451a4`, TA: offsets up to +0x5a4). They copy resource addresses
  into the descriptor for tracking.
- Each builder stores its sequence in its own command object: TA at +0x464
  (size +0x468), 3D at +0x14 (+0x18), compute at +0x1e8 (+0x1ec). So TA and 3D
  are separate commands.
- **R9 starts with the TA record.** Its +0x30 block gives
  `VDM_CONTEXT_STORE_TASK0/1/2` = PDS pair `0x910/0x4820`, PDS sizes
  `0x…21001002`, `0xc40`, and `RESUME_TASK0` = pair `0xc50/0x4820`. The VDM
  stream base is at +0x28. PDS pairs of this form exist nowhere else.
- **The 3D state is in R9 too, as plain fields, not packed registers:** two
  0x3c-byte background-object descriptors at R9+0x280 `{data 0x2740, code
  0x26c0, …, 0x3c030, …, 0x2a40, 0x402}` and R9+0x500 `{0x2900, 0x2880, …,
  0x3c000, …}`. These point at the PDS programs the `load` variant changes
  (code heap 0x2600/0x27c0). So the Start3D register block (command+0x68 /
  +0x3b0) is probably built by the kernel from such fields.
- Consequence for Linux: Mesa already computes fragment registers
  (`rogue_fwif_cmd_frag`). The driver only needs the slot ↔ register mapping
  (above) and register names for 0xf18…0xfd8 and 0x618…0x6d0, then it packs
  Mesa's values into Apple's Start3D block, as compute does.

## The render record (2026-10-30)

**R9 is one render record: TA part at +0, 3D part at +0x120.** The firmware
reads it in place:

- TA (base R9+0): 64-bit block +0x30..+0xb0, 32-bit block +0x3b4, VDM
  stream base +0x28, word 7 +0x538, FinalizeTA +0x538/+0x5a4.
- 3D (base R9+0x120): 64-bit block R9+0x188..+0x268, 32-bit block
  R9+0x4d0..+0x4f8. Slot order matches Rogue's fragment registers:
  0xf18 `isp_bgobjdepth` = 1.0f (the clear depth), 0xf80 `isp_bgobjvals` =
  0x300, 0xf88 `isp_aa` = 0xf, …, 0xf38 `isp_ctl` = 0xffffffff (as
  submitted).
- Background-object descriptors follow each 3D block (R9+0x280, R9+0x500).
- No overlaps between the TA and 3D blocks.

**The kernel does not patch R9 during submission.** `capture.m` now copies
all regions into a `MAP_SHARED` file (`post.bin`/`post.idx`) with plain
`memcpy` right after the trap; the process dies shortly after, partway
through. R9 is identical before and after. R1 is a fence/stamp table:
entries go from `{0, 0xff}` to `{1, id}`.

StartTA's other words (kext `FUN_fffffff006035fa4`): 3 = descriptor+0x20;
4 = fw address of a context buffer (`param_3+0xcf0`); 5 = global firmware
buffer + 4; 6 = channel buffer; 7 = record+0x538; 8 = descriptor+0xc
(context id: the firmware stores it to `CONTEXT_MAPPING0`); 9..15 = context
and flag values; 16/17 = record+0x474 / +0x574; 20 = descriptor+0x568
(stamp); 24 = context buffer+0x6c. Each needs a Linux-side equivalent (PM
and parameter buffers, stamps, unit states), worked out as was done for
compute.

## Register names matched by value (2026-10-30)

Against Mesa's packing (`pvr_arch_job_render.c`, `csbgen/rogue/cr.xml`):

| Slot | Captured | Mesa field | Status |
|---|---|---|---|
| 3D 0xf18 | 0x3f800000 | `ISP_BGOBJDEPTH` = fui(1.0) | confirmed |
| 3D 0xf80 | 0x300 | `ISP_BGOBJVALS`: mask (bit 8) + enablebgtag (bit 9) | confirmed |
| 3D 0xf88 | 0xf | `ISP_AA` (mode in bits 0–1; upper bits unknown) | likely |
| 3D 0xf38 | 0xffffffff in the template | `ISP_CTL` (kernel-filled?) | named by IMG header |
| TA 0xcc0 | 0x900 | `TE_PSG`: region_stride 0x100, bit 11 | likely |
| TA 0xc90 | 0x640 | `PPP_CTRL`: fixed_point_format (bit 9), bits 6/10 | likely |
| TA 0x438–0x460 | PDS pairs | `VDM_CONTEXT_STORE/RESUME_TASK0–2` (Mesa `vdm_ctx_store/resume_task*`) | named by IMG header |

The TA 32-bit block (R9+0x3b4: 0xc78, 0xc88, 0xc98, 0xc18, 0xc08, 0xc10,
0xc20, 0xc28) is zero in the userspace template, and only R9's raw
width/height change with the target size. So these are most likely the
size-derived TE/tiling registers (`te_screen`, `te_mtile1/2`, `teaa`,
`isp_mtile_size`, …) that upstream computes in `pvr_hwrt.c` and the iOS
kernel fills in its own copy. Which slot is which is still open.

Lead: kext `FUN_fffffff006031f18` is iOS's counterpart of upstream
`pvr_hwrt.c`. It uses 32×32 tiles (`(w + 0x1f) >> 5`) and sample factors for
1/2/4/8 samples, rounds macrotiles exactly like upstream
(`round_up(DIV_ROUND_UP(tiles, 4), 4)`), and packs register values into a
render-target object (+0x100 combines last-tile indices, `TE_SCREEN`-style;
+0x10/+0x20 are buffer sizes). Following those fields to the hardware
command's +0x3b4 block gives the slot names. The values themselves can come
from upstream's `hwrt->common` (`te_screen`, `te_mtile1/2`, `teaa`,
`isp_mtile_size`).

More findings:
- Nothing in the kext writes the record's +0x3b4 block, so it may
  legitimately be zero. TA opcode 4 is only a trace op (same arguments as the
  timestamp ops).
- The `size128x32` change at R23+0x120 (`0x00040001` → `0x000c0000`) is PPP
  `STATE_TERMINATE0` (clip_right bits 18–26, clip_bottom bits 0–8): last tile
  column 1 → 3, last tile row 1 → 0, with 32×32 tiles. Userspace computes it,
  as Mesa does.
- So the TA needs from the kernel side only: the three PM addresses (word-4
  buffer), unit-state/stamp arrays, and context ids. The open question for a
  first replay is the PM buffers' contents (MList, VHEAP table, macrotile
  array; on iOS kernel-allocated, not captured). Upstream's HWRT dataset
  provides them, so the Linux path goes through Mesa-allocated buffers.

## Next

Decode the PPP state words (Mesa `ppp.xml`, `ipf.xml`) and the register lists
(R13, R23), and locate the TA and 3D firmware work items (the render counterpart of the compute work
descriptor in COMPUTE.md). Then reproduce the triangle on Linux, as was done for
compute.

## Geometry submission, decoded (2026-10-30)

Sources: the firmware decompiled with Ghidra (raw Thumb image), the iPadOS 17
kext, and the **unstripped iOS 10 T8010 kext** from
[userlandkernel/ios-unstripped-kexts](https://github.com/userlandkernel/ios-unstripped-kexts)
(`kexts/10.0/T8010/AGX.kext`, 3647 symbols: `AGXTAChannelG9`,
`AGXRenderTargetMemoryG9`, `AGXParameterManagement`, ...). iOS 10 builds
register lists in the kernel rather than microsequences, but the registers and
their sources are the same ones iOS 17's firmware programs, so it names them.

**Rings and queues.** The firmware's work rings come in triples per priority:
ring 0 geometry, ring 1 fragment, ring 2 compute (X+0x18/+0x28/+0x38 data,
X+0xc+0x10·i indices). A ring entry's +0xc must equal the ring's engine. The
entry names a queue and a scheduling slot (+0x12); slot → {queue, engine} is
kept at fw 0x5b930 (stride 0x28). Command types: 0 geometry (microsequence
at +0x464, size +0x468; dispatcher fw 0x115fc), 1 fragment (+0x14/+0x18) and
2 fragment variant (+0x498; fw 0x12340), 3 compute (+0x1e8). The kext's trace
emitter (`FUN_…9284`) confirms the four types.

**Geometry command** (fields the firmware reads): +0x00 type 0 (non-zero takes a
cancel path), +0x0c context id, +0x14 context (0x84 bytes, cache-cleaned),
+0x18 free-list index, +0x20 free-list descriptor (0x74 bytes; the firmware
writes +0x0c into its +4), +0x24 parameter-manager slot, +0x554/+0x558
completion stamp address/value.

**StartTA (opcode 5, 26 words)**, case 5 of the interpreter:

| Word | Meaning |
|---|---|
| 1 | 8 × u32 → 0xc78, 0xc88, 0xc98, 0xc18, 0xc08, 0xc10, 0xc20, 0xc28 (then 0xd20=0, 0xce0=1) |
| 2 | 28 × u64 → 0xc90, 0xc38, 0xc40, 0xc00, 0xc80, 0x428, 0xcc0, 0x438–0x460, 0x470, 0x418, 0x408, 0xf058, 0xf060, 0xf068, 0xf070, 0xf038, 0xf040, then six writes of 0x11030 with 0x11ff8 = 0..5 |
| 3 | free-list descriptor; its first word goes to unit state +0x10 |
| 4 | parameter-manager slot: +0xa0 → 0x2d8, +0xa8 → 0x240, +0xb0 → 0x248 (masked to 16 bytes); +0xb8 ≠ 0 skips the kick and raises TA_FINISHED (RGX 0x130 = 0x20) |
| 5 | geometry unit states (X+0x134 page + 4, stride 0x14) |
| 6 | stored in unit state +0xc |
| 7 | pointer to a skip flag (also set when word 22/23 ≥ the {lo, hi} at word 24) |
| 8 | context id → `CONTEXT_MAPPING0` (0xf078) |
| 11 | free-list index: `fw 0x1703c` loads the free-list registers when it changes |
| 16 | pointer: 0 = fresh parameter state (PM init kicks 0x290, 0x198, 0x258, 0xcb8, then 0xc68), else resume (`fw 0xd44c`) |
| 18 | sets bit 30 of RGX 0x80 |
| 24 | cancel threshold {lo, hi} |

The kick is RGX 0x400 = 1. **FinalizeTA (opcode 6, 15 words):** 1 slot, 2
free-list descriptor (+0x10 counts jobs), 3 unit states, 5 skip flag, 6
context id (cache flush 0xe230 = id << 2 | 0x803), 8 resume pointer (written
on a context store), 11/12 stamp address/value, 13 bytes to skip on a store,
14 a state block. It waits for `VDM_CONTEXT_STORE_STATUS` bit 0, saves the
PM registers (0xe0xx) into the slot, and flushes. Event bits are RGX
`EVENT_STATUS` bits: compute waits on 4 (COMPUTE_FINISHED), geometry on 0x20
(TA_FINISHED); 0x40 is TA_TERMINATE, 0x80 PM_OUT_OF_MEMORY.

**Register names from iOS 10** (`AGXTAChannelG9::generateSKURegisterList`,
`AGXTACommandDescriptor::loadRenderTargetMemoryData`,
`AGXRenderTargetMemoryG5::halComputeGeometry`, for w×h, 32×32 tiles,
mt = round_up(⌈tiles/4⌉, 4)):

| Register | Value |
|---|---|
| 0xc38 | region headers (ring buffer of the render target) |
| 0xc40 | tail pointer cache |
| 0xc00 / 0xc80 | sample count code (0 for 1×) / sample positions (0x88 for 1×) |
| 0xc98 | (h−1) << 16 \| (w−1) |
| 0xc18 | (tiles_y−1) << 12 \| (tiles_x−1) |
| 0xc08 / 0xc10 | mt_x << 18 \| mt_x << 10 \| 3·mt_x (same for y) |
| 0xc20 | mt_x · mt_y |
| 0xc78 / 0xc28 | constants 0x88 / 0x20000 |
| 0xc88 | 2 \| userspace bits |
| 0xc90, 0x428, 0xcc0, 0x438–0x460, 0x470, 0x408 | from the userspace record (PPP_CTRL, PDS control, TE_PSG, VDM context tasks, stream base) |
| 0xf038–0xf070, 0x11030 | from the userspace record (`loadTAFields`) |

**Parameter manager.** The free-list descriptor (iOS 17 kext
`FUN_fffffff006040ba8`): +0x18 stack base (a flat u32 array of PM page
numbers, physical address >> 12, as upstream `pvr_free_list.c`), +0x20 its
size, +0x24 = 0, +0x40 = 0xffffffff (empty: the firmware grows the stack from
128 KiB blocks the kernel lists), +0x48 = 0. `fw 0x16634` loads +0x18 →
0x210, +0x24/+0x40 → 0x220/0x224, +0x48/+0x4c → 0x390/0x394; the fragment
side packs +0x24 \| +0x40 << 22 into 0x230. Slots are 0x100 bytes with the
macrotile array (+0xa8) and list (+0xa0) per slot, the VHEAP table (+0xb0)
shared, +0xc0 the header. The self-test pre-fills the stack (top = n−1)
instead of implementing growth.

**Self-tests** (`apple_selftest=5/6`, `tools/tri-blob.py` builds
`apple/gpu-tri.bin` from a capture): both map the captured regions at their
iOS addresses (code heap at the PDS/USC bases); 5 kicks the TA on a stream of
PPP terminate state + STREAM_TERMINATE with fresh PM state and driver
buffers, 6 then runs the captured triangle stream. Each logs the stamp, unit
states, slot, free-list counters, RGX event/PM registers, a decoded MMU fault
and which buffers the hardware wrote.

### First device runs (2026-10-30, `out/resume/driver7..12-*.log`)

- **Command scheduling fields:** the firmware takes the scheduling slot from
  the command (+0x55c for geometry, +0x278 for compute) and a token at
  +0x558/+0x274 whose bits 8–14 pick the scheduling entry; it must match the
  work-ring entry's slot, or the firmware dereferences the other slot's
  engine number (crash at fw 0xf01a, `out/resume/driver7-ta.log`). Command
  sizes the queue parser cache-cleans: geometry 0x5c0, fragment 0x908 /
  0x638, compute 0x2c8.
- **The geometry path works up to the hardware.** The queue on ring 0 is
  accepted, StartTA runs (unit state +4 = 1, trace code 0), the free list is
  loaded (`0x224` = 0x3ff), the PM init kicks complete (PM stack top moves to
  0x3d2: 45 pages taken), and the kick reaches the VDM: with the stream
  unmapped, the GPU MMU faults reading it (0x400c0040, read). The skip flag
  (slot +0xb8) does not survive dispatch; the firmware clears it.
- **The TA does not finish yet.** A bare STREAM_TERMINATE leaves the TA
  silent. With the PPP terminate state the iPadOS stream ends with (PPP_STATE
  → `02000000 00040001 00000000`, then `c0000000`) the TA fetches code at
  PDS base + 0x4000 (the iPadOS code heap has USC code there); with that heap
  mapped there is no fault, but no TA_FINISHED/TA_TERMINATE either, and
  `JONES_IDLE` = 0x3f7f (VDM, PM, tiling, USC idle). Copying the record's
  `0x…20000001` words into 0x470/0xf058 makes the TA fetch PDS base +
  0x20000000: the userspace record is not the hardware block; the kernel
  patches it (its 0xc38..0xc80 slots hold 0x1_00148020..2c, references into
  R24, not addresses).
- Firmware trace: the SKU debug ring (heap 0x70000, 36-byte records, enabled
  by U[0] = 3) and the heap itself are readable from the device with
  `dd if=/dev/mem` at the heap's physical address. Event codes: 0x102/0x103
  bracket event handling (args: group, wait mask, events), 7/8 StartCompute
  and FinalizeCompute, 0 StartTA, 0x101/0x105/0x106 idle. Events are masked
  with 0x83ec (= RGX `EVENT_ENABLE`) and grouped: 0x12c (compute, pixel-BE,
  TA_FINISHED, 3D_MEM_FREE), 0xc0 (TA_TERMINATE, PM_OOM), bit 15.

**Variant runs (driver13–15, `tools/ta-variants.sh`, `apple_ta_variant`):**
the 0x4000 fetch comes from the PPP terminate (the header is Mesa's
`pres_terminate`, TERMINATE0 = clip 1/1, so the words are right) and is
satisfied by the iPadOS code heap; clearing 0xc28 or the whole 32-bit block
changes nothing. Restoring the record's 0x470 value makes the TA read PDS
base + 0x20000000 (requester 8), so 0x470 is read as a PDS-relative pointer
during a normal run. No combination of the record's 0xf058–0xf040, 0x418,
0x470 (0x915/0x910) and VDM task values completed; the units stay idle with
no event. The iOS 17 kext never writes the record's 32-bit block nor
computes the tiling registers (`FUN_fffffff006031f18` computes them into a
context object, `FUN_fffffff0060506d4` copies them to +0xc18..+0xcd8 /
+0x6d8..+0x730 of it), so where they reach the hardware is still open.

**The iPadOS R9 is a command stream, not the register block (2026-10-30,
`out/ios-render/base`, `tools/late-diff.py`).** A capture that keeps
re-copying the command regions for 300 ms after the submit (`late.bin`; the
render target fills in that window) shows R9 unchanged: nothing patches it.
Its layout is the kext's stream format (`FUN_fffffff0060367d0`): version
0x10000 and size 0x830, a 0x20-byte item header (count 4, body size 0x808,
type 1 = render), and the 0x808 body at R9+0x28 (`FUN_fffffff0060451a4`).
The body is a compact geometry state in Mesa's order: VDM stream base
0x1_00040000, 0x640, four table addresses (0x1_00148020.., also listed in
R14), 0x0003000524001002, 0x900, VDM task words. The kernel builds the
firmware's register block from it in an object our captures cannot see, so
the earlier copies put record words into the wrong registers. Register
semantics come from the iOS 10 kext instead: 0x408 = VDM_CTRL_STREAM_BASE
(masked to 4 bytes), 0x470 = VDM_CONTEXT_STATE_BASE (masked to 16), 0x418 =
VDM_CALL_STACK_POINTER (0), 0xcc0 = TE_PSG, 0xc90 = 0x1e3ce508 (iOS 10
constant). Mesa sets TE_PSG `completeonterminate` on the last geometry job;
the self-test now has variants for that (2048), 0xc90 (4096) and a real
VDM context state buffer (8192).

**0x470 is a PDS-relative pointer; the VDM finishes its stream (driver16–18,
2026-10-30).** Pointing 0x470 at a buffer makes the GPU read PDS base +
that address (requester 8), and with a zeroed 64 KiB buffer it keeps reading
past the end (requester 10): it runs as a PDS program, not as context data.
The iPadOS value's low word is PDS + 0x20000000, outside every captured
region. With 0x470 = 0x910 (the iPadOS code heap's zeros + HALT at 0x920)
there is no fault but still no completion, with or without TE_PSG
`completeonterminate`. A register read-back after the run (`tools/rgx-sweep.sh`:
`devmem` over 0x400–0x480, 0xc00–0xd40, 0x200–0x3e0, 0xf000–0xf080) shows
everything programmed as intended and the VDM past its stream: 0x410 =
stream + 0xc (after PPP_STATE and STREAM_TERMINATE), 0xc30 = 0xc0000000 (the
last block), 0xd20 = 1, 0xc48 = 8. TE_PSG reads back 0x20000 (region stride
did not stick). So the stall is after the VDM: the PPP/TE never terminate
(no region headers, PM writes nothing, no event).

**Register meanings from writable-bit masks (`tools/rgx-masks.sh`,
`out/resume/rgx-masks.log`).** With powervr loaded and the GPU idle, each
register gets all-ones and is read back:

| Reg | Writable | Meaning |
|---|---|---|
| 0x408 | [39:2] | VDM_CTRL_STREAM_BASE |
| 0x418 | [39:3] | VDM_CALL_STACK_POINTER |
| 0x428, 0x470, 0xcc0 | [39:4] | 16-byte-aligned addresses (context-state bases) |
| 0x420 | 14 bits | |
| 0x438–0x464 | 64 bits | VDM context store/resume tasks |
| 0xc00 | 3 bits | TE_AA |
| 0xc08, 0xc10 | 27 bits | TE_MTILE1/2 |
| 0xc18 | 0x1ff1ff | TE_SCREEN |
| 0xc20 | 19 bits | |
| 0xc28 | 0x627ff | TE_PSG (stride 0–10, bits 13, 17, 18) |
| 0xc30 | 32 bits | VDM's last block (reads 0xc0000000 after a run) |
| 0xc38, 0xc40, 0xcb0 | [39:6] | region headers, TPC, (TA_RTC?) |
| 0xc48 | 11 bits | |
| 0xc78 | 8 bits | |
| 0xc80 | 64 bits | PPP_MULTISAMPLECTL |
| 0xc88 | 13 bits | PPP_CTRL |
| 0xc90 | 64 bits | PDS_CTRL (iOS 10: 0x1e3ce508) |
| 0xc98 | 0x7fff7fff | PPP_SCREEN |
| 0xca0 | 3 bits | |
| 0xce0, 0xd20 | 2, 1 bits | |
| 0x210/0x218, 0x240, 0x248, 0x2d8 | [39:4] | PM free stacks, MTILE array, VHEAP table, MLIST |
| 0x220, 0x224, 0x390, 0x394 | 22 bits | PM stack pointers / counters |

The iOS 10 constants fit: 0xc28 = 0x20000 is TE_PSG `completeonterminate`.
Variant 32768 programs these meanings (PDS_CTRL, PPP_CTRL 0x202, TE_PSG
0x20001, zeroed buffers for 0x428/0xcc0/0x418); the TA still stops after the
VDM. Mesa's geometry-only stream is the same as ours (PPP terminate state +
STREAM_TERMINATE).

**The record mapping (2026-10-30).** The iOS 10 kext's
`AGXTACommandDescriptor::loadTAFields` + `AGXTAChannelG9::generateSKURegisterList`
map the userspace TA record onto the same register list iOS 17's StartTA
takes. Applied to the iOS 17 record at **R9+0x28** (the stream item body),
every field fits the register masks: +0x00 → 0x408 (0x1_00040000, the VDM
stream), +0x08 → 0x470 (0x640: code-heap PDS data `0x580, 0x10` with
`DOUT; HALT` at 0x660), +0x30..+0x58 → 0x438..0x460 (VDM context tasks, PDS
code at 0x900/0xc40), +0x60/+0x68 → 0x428/0xcc0 (0x1_0014e240/e040,
16-byte-aligned buffers in R24), +0x70/+0x78/+0x88/+0x90 → 0xf058..0xf070,
+0xa0/+0xa8 → the 0x11030 list, +0xb0/+0xb8 → 0xf038/0xf040, +0xc0 bytes →
PPP_CTRL bits. The earlier copies were 0x28 bytes off. The self-test's
`pvr_apple_ta_job_triangle()` now uses this mapping (variant 65536 for the
empty stream; 131072 skips straight to the triangle).

Next (offline): find the iOS 17 kext code that patches the TA record before
submission (the 0xc38–0xc80 references, 0x470, 0x418, 0xf038–0xf070,
0x11030) and what the TA fetches at code offset 0x4000; then rerun 5/6
without a reboot (`rmmod`/`modprobe` with the new module works).

### The geometry stage completes (2026-10-30, `out/resume/driver20-record.log`, `driver21-output.log`)

With the record mapping above, **both TA jobs complete**: the empty stream
(variant 65536) and the iPadOS triangle (131072, stream 0x1_00040000). The
completion stamp advances and the unit state returns to idle with no fault.
Variant 262144 dumps what the TA wrote:

- **Empty stream:** region headers written for every tile (256 non-zero
  words), MLIST 5 entries, the MTILE array filled (`0x00400400` pairs), PM
  stack top 0x3ff → 0x3fa. The parameter-buffer pages hold only PM
  bookkeeping (`0x0ed..001 00000008` page links).
- **Triangle:** PM stack top → 0x3dd, MLIST 13 entries, 0x3a0 = 0x10. The first
  region headers change (`00000000 00000000 00608000 60000000 00000000
  00002000 00209000 …`). Two PM pages hold a **tile control stream**:
  `2c070000 00000009 c0000000`, a primitive-block entry followed by the
  stream terminate. One page holds what looks like primitive/vertex data
  (`7f000000 00000000 000001c0 000000c0 00800000 00000140 …`), and another
  `00000001 80000000 00000001 84000008 00000001 84000000`.

So the VDM, PPP, TE and PM all run on Linux with the iPadOS geometry state.
The output is a parameter buffer the 3D stage (Start3D, op 7) consumes.

Next: Start3D with the iPadOS fragment record (same treatment: the iOS 10
kext's `load3DFields`-style mapping onto the 3D register list), pointing it at
this run's region headers and parameter buffer, then read back the render
target.

## First rendered triangle (2026-10-30, `out/resume/driver22-frag.log`, `driver23-frag.log`)

**The fragment stage renders the iPadOS triangle on Linux, identical to
iPadOS's output:** after the triangle's geometry job, a Start3D job on the
same parameter-manager slot fills the 64x64 target with 3584 clear pixels
(`ff000000`) and 512 triangle pixels (`ff4080bf`). This is the same count and
the same (tiled) layout as the target iPadOS rendered (`late.bin` R4).

How the fragment job is built (`pvr_apple_layout_write_3d_job`,
`pvr_apple_3d_job_triangle`):

- **Queue:** work ring 1 (X+0x28, producer at ring indices + 0x18), command
  type 1 with its microsequence at +0x14 (size +0x18) and a 0x84-byte context
  at +0x1c. The scheduling descriptor sits at +0x89c (stamp), +0x8a4 (token)
  and +0x8a8 (slot byte), with the sequence at +0x8b4; fw 0xe184 reads the
  three types' fields side by side. The command holds its register blocks
  itself, the 64-bit block at +0x68 and the 32-bit block at +0x3b0 (the
  dispatcher preloads both).
- **Start3D (op 7, 29 words, fw case at interpreter 0xadb2):**
  - w1/w2: register blocks.
  - w3: the geometry job's PM slot. fw 0x1622c loads the PM scene from it,
    including `ISP_MTILE_BASE` (0xf20) from slot+0xa8.
  - w4: unit states (the X+0x134 page) + 8. StartTA uses +4 of the same page.
  - w5/w6: partial-render counters. w7: skip flag. w8: channel. w9: the
    command. w10: context id.
  - w18: a deferral word (non-zero delays the kick). w25: sequence.
  - w26–w28: cancel threshold, as StartTA's.
- **Wait:** `PIXELBE_END_RENDER` (event bit 3, word 0x8 << 6).
- **Finalize3D (op 8, 19 words):**
  - w1: sequence. w2/w3: stamp address and value. w4: PM slot.
  - w5: a counter block. w6 = 1. w7: unit states. w8: skip.
  - w9: partial. w10: channel. w11: command. w13: command+0x8c0.
  - w17 = 0x4c: the jump to End. w18: command+0x8f0.

Register blocks, from the firmware case, the writable-bit masks
(`out/resume/rgx-masks-3d.log`) and Mesa's Rogue layouts:

| Block slot | Register | Value | Source |
|---|---|---|---|
| 32[0] | 0xf18 `ISP_MTILE_SIZE` | 0x00040004 | iOS 10 halComputeGeometry |
| 32[1], [2] | 0xf80 `ISP_BGOBJDEPTH`, 0xf88 `ISP_BGOBJVALS` | 1.0f, 0x300 | iOS 17 record body+0x4a8 |
| 32[4] | 0x6d0 | 0x1f | iOS 10 constant |
| 32[5..7] | 0x618/0x620/0x628 `EVENT_PIXEL_PDS_CODE/DATA/INFO` | 0x2a40, 0x3c040, 0x402 | record end-of-tile pair |
| 32[8] | 0xf38 `ISP_CTL` | 0x21000f | iOS 10 formula, 4-byte pixels |
| 32[9..11] | 0x3e00, 0xfd8, 0x4070 | 0x408, 4, 0xf9 | iOS 10 |
| 32[12..17] | 0x11d0..0x11f8 | tan 15°/w, tan 60°/w, 16w | iOS 10 (line rasterization) |
| 64[0] | 0xfa8 | 0x88 | sample positions |
| 64[1], [2] | 0xfb0/0xfb8 `ISP_SCISSOR/DBIAS_BASE` | 0 | |
| 64[3], [4] | 0xfc0, pipes 0/1 (`BLACKPEARL_INDIRECT`) | 0 | [39:4] |
| 64[5..9] | 0xf48 `ZLSCTL`, 0xf50..0xf68 load/store bases | 0 | |
| 64[10] | 0xf28 `ISP_RGN` | 0x14 | iOS 10 (RTM+0x18 >> 2) |
| 64[11..14] | 0x6a0..0x6b8 `PDS_BGRND0..3` | 0x26c0/0x2740, 0, 0x3c030, 0x0080000000800000 | record background pair |
| 64[15] | 0xf30 `ISP_AA` | 0 | |
| 64[16..21], [22..27] | 0x11020, 0x11080 per cluster (0x11ff8 select) | 0, 0x1d3 | iOS 10 |
| 64[28] | 0xfd0 | 0 | |

The record's background descriptor decodes as Rogue's `PDS_BGRND0..3`
followed by the end-of-tile `EVENT_PIXEL_PDS_DATA/CODE` and `INFO`. The
clear colour comes from R13+0x48 via PDS data 0x3c030. The end-of-tile PDS
data at 0x3c040 points at an image descriptor at R13+0x58, whose address word
0x8000a000 is R4 (0x1_00014000) >> 1.

Open: the job does not signal `PIXELBE_END_RENDER`. Events after the run are
0x4110 (ISP_END_MACROTILE, PM_3D_MEM_FREE, ZLS_FINISHED), and the GPU MMU
records a write fault at address 0 (requester 9; 25 with scratch buffers for
0xfc0 and the depth/stencil bases).

**The fragment job completes with GPU VA 0 mapped (`driver27-va0.log`,
`driver28-va0.log`).** The fault is a write to VA 0 that carries no data: a
page filled with 0xaa is unchanged afterwards. With any page at VA 0 the job
signals `PIXELBE_END_RENDER`, Finalize3D writes the stamp, and the output is
again identical to iPadOS's. Moving 0xfc0, the depth/stencil bases, 0xfd0,
0x11020, the scissor/depth-bias bases or `ISP_CTL` skip_init_hdrs does not
move it (`driver24..29`). The requester alternates between 9 and 25, which
differ in one bit, as two pipes would. The likely source is the end-of-tile
store: its image descriptor (R13+0x58, `fb05050a 00007e01 8000a000
80000000 0 0 0`) carries a second, zero address, which would give a masked
(empty) write. On iPadOS, GPU VA 0 is the code heap (R2), always mapped, so
such writes are harmless there. The driver can reserve a page at VA 0 in
each GPU VM in the same way.

**Resized render, on screen (`driver31/32-512.log`, `out/resume/target512.bin`).**
`apple_rt_size=512` resizes the captured scene to a 512x512 target at GPU VA
0x1_00200000. It patches the words the 128x32 capture changes (image
descriptor size and address, PPP terminate clip, viewport) plus the
geometry job's 0xc98/0xc18 and the line-rasterization scales; the macrotile
grid is unchanged up to 512. The triangle covers 32768 pixels (1/8 of the
target, as at 64x64). The target is in full Morton order (y bit first).
Tiles without geometry are not cleared: `ISP_CTL` bit 17 does not make the
ISP process them, so the empty-tile skip comes from somewhere else (open).
The self-test leaves a copy at `<debugfs>/apple_target`, and
`tools/show-target.c` untwiddles it onto /dev/fb0 after the framebuffer
console is unbound.

## Render jobs through the powervr UAPI (2026-10-30)

`tools/pvr-render-test.c` renders the iPadOS triangle through the powervr
UAPI only (VM_MAP, CREATE_FREE_LIST, CREATE_HWRT_DATASET, a render context,
one SUBMIT_JOBS with geometry and fragment jobs carrying the Apple stream
extension). Output: 3584 clear and 512 triangle pixels, identical to iPadOS,
in about 0.5 ms (`out/resume/uapi9.log`, six in a row: `uapi14-six.log`).

- **38-bit data addresses.** The capture relocated to 0x3_…, 0x10_… and
  0x20_… renders; to 0x40_… and 0x80_… the geometry job stalls without an
  MMU fault (`reloc3/4.log`). Apple devices publish powervr's heaps below
  2^38 (general 0x8_0000_0000, PDS 0x2a_0000_0000, USC 0x2c_0000_0000, …);
  the firmware's code bases follow. Page tables stay 40-bit (powervr's MMU
  rejects anything else).
- **Fragment command +0x20/+0x24** (free list, PM slot) are read when a
  fragment job retires (fw 0x12b98).
- **A compute job between renders crashed the next Start3D: the fragment
  job overtook its geometry job** (firmware trace `out/resume/trace2-*.bin`,
  SKU ring at heap 0x70000: good renders log 0x111 ring 0 dispatch, 0x000
  StartTA, 0x001 FinalizeTA, 0x111 ring 1, 0x004 Start3D, 0x005 Finalize3D;
  the failing one only the fragment dispatch). Within one SUBMIT_JOBS,
  powervr orders a geometry/fragment pair through the HWRT reservation, but
  a job's fence is added to it only after all jobs collected their
  dependencies; IMG's firmware orders the pair itself. The Apple path now
  makes each fragment job depend on the last geometry job (and each
  geometry job on the last fragment job). Notes on the firmware's free-list
  table, kept for reference: geometry dispatch registers `table[cmd+0x18] =
  cmd+0x20` (fw 0x8dd60), the current id per engine is at 0x8df5c/0x8df60,
  and retirement (fw 0x130a6) saves PM state, resets current ids and clears
  `table[[cmd+0x20]+8]`; a Start3D with no geometry state before it loads a
  null entry (fw 0x1703c → 0x16634).

**Verified (`out/resume/uapi21-clean.log`, `uapi22-parallel.log`):** on a clean
boot, the previously failing sequence (three renders, compute, renders)
passes, then 30 mixed render/compute rounds, then four processes submitting
15 renders and 15 compute jobs each concurrently: 120 of 120 pass, no
firmware crash, no timeout.

## Varyings and textures (2026-10-31, `out/ios-render/{vary,vary2,vary3,flat,noperspective,tex}`)

Six captures, each one change from `base` (capture.m `kVariants`, kind
1-6). Vertex shader: positions as base, colour red/green/blue per vertex,
uv = position + 0.5, k = vid / 4. Comparison script: see the session of
2026-10-31; the values below are from `R2` (code heap: fragment USC at
+0x40, fragment PDS from +0x140, repeated three times), `R10+0x1c0`
(pipeline state) and `R3+0x28` (draw state).

| Variant | Fragment PDS data (DOUTI sources) | PDS code | R10+0x1c0 / +0x1d0 | R3+0x2c |
|---|---|---|---|---|
| base (constant) | none | - | 4 / `20020001` | `00800000` |
| vary (vec4 col) | `03000000 0`, `030d0202 80400000` | `f0000004 f400000c` | 8 / `20040001` | `00800420` |
| vary2 (col.rg, uv) | `03000000 0`, `030d0606 00400000`, `03050202 81400000` | `f0000004 f000000c f4000014` | 10 | `00800820` |
| vary3 (col, uv, k) | `03000000 0`, `030d0808 00400000`, `03050404 01400000`, `03010202 81c00000` | (4 DOUTI) | 11 | `00800820` |
| flat (vec4 col) | none (data `c0`) | - | 8 | `00800410` (R3+0x28 `0x100`) |
| noperspective | `030c0202 80000000` | `f4000004` | 8 | `00800410` |
| tex (vec2 uv) | `03000000 0`, `03050202 80400000` | `f0000004 f400000c` | 6 / `20020001` | `01000410` |

Reading (DERIVED, to test on hardware):

- `f0000004` is a DOUT of type 4 (Rogue: DOUTI, iterator issue) from data
  q0, q1, …; the last one has END. One DOUTI per varying, plus a first one
  (`03000000 00000000`) for perspective-correct varyings: noperspective
  has neither it nor the perspective bits, so it is the W (1/w) iterate.
- DOUTI source word 0: byte 2 = `(components − 1) << 2 | perspective`
  (`0d` vec4, `05` vec2, `01` scalar, `0c` vec4 without perspective);
  bytes 0 and 1 = the varying's location, `2 + 2 × (components of the
  varyings before it)` (vary3: k 2, uv 4, col 8); byte 3 = `03`.
- DOUTI source word 1: bit 31 last, bit 22 perspective (clear for
  noperspective), bits 23+ the destination in units of two dwords (vary3:
  col 0, uv 2, k 3).
- Flat varyings are not iterated: the fragment shader reads them with
  `2314 01dd 01ll 0200` loads (as the workgroup ID in compute).
- Fragment-side reads (`?30a`, `?308`): W0 bits 11-12 = `4 − components`,
  W0 bit 9 = perspective (`030a` vs noperspective `010a`); they write half
  registers, so a varying can feed the colour output (`211c 0800`) with
  no conversion (vary, vary2).
- Texture: `1308 0300 8000` iterates the uv, `f518 0100 8108 0700 0200`
  samples into half registers r0-r1. Descriptors: see "Replayed on Linux"
  below.
- Vertex-side state: R10+0x1c0 counts the vertex output dwords (4 + the
  varyings, rounded), R10+0x1d0 `2002`/`2004`, R3+0x2c the varying layout.

### Replayed on Linux (2026-10-31)

`tools/tri-blob.py out/ios-render/VARIANT out/gpu-tri-VARIANT.bin`, then
`TRI_BLOB=/run/gpu-tri-VARIANT.bin pvr-render-test [OUT.raw]` (OUT.raw is
the 64x64 RGBA8 target). Results (TESTED):

- `vary`: 512 triangle pixels, 513 distinct colours, smooth across the
  triangle (`0xff0a02f3` at the top corner, `0xff06ed0c` at the bottom
  right): Apple's DOUTI + iterate code interpolates on Linux.
- `tex`: 512 pixels from 12 of the 16 texels, nearest sampling, bytes in
  the order the texel words hold them reversed (texel `ff00ff40` lands as
  `ff40ff00`): the captured texture is BGRA, the target RGBA.

Three things had to change for a capture other than `base`:

1. **Capture directories can hold region sets of two runs** (a session
   that captured twice into the same directory: 26 regions at CPU
   0x3da…, 27 at 0xa98…). `tri-blob.py` keeps the newest set (split at a
   CPU-address gap above 4 GiB, newest by mtime). The GPU addresses of
   every selector-9 allocation are identical between `alloc-base` and
   `vary`, so the fixed region→GPU map holds for every variant so far.
2. **PDS offsets move with the code heap**: one more fragment-shader block
   (`vary` 3 blocks vs `base` 2) shifts every later PDS program by 0x40.
   `pvr-render-test` now reads them from the capture's userspace record
   R9 (0x200004000) instead of fixing base's values:

   | R9 offset | Register (stream field) | base |
   |---|---|---|
   | +0x30 | geometry 0x470 | `0x640` |
   | +0x58/+0x60/+0x68 | store program (3 x 64-bit) | `…24001002`, `0x900`, `0x910_00004820` |
   | +0x70/+0x78/+0x80 | resume program | `…21001002`, `0xc40`, `0xc50_00004820` |
   | +0x98/+0xa0/+0xb0/+0xb8 | PDS state 0-3 | `0x915_20000001`, `0x920`, `0xc51_20000001`, `0xc60` |
   | +0x280..+0x298 | fragment background (4 x 64-bit) | `0x26c0_00002740`, 0, `0x3c030`, `0x800000_00800000` |
   | +0x2b0 low / high | event_pixel_pds_data / end-of-tile PDS code (0x618) | `0x3c040` / `0x2a40` |
   | +0x2b8 | event_pixel_pds_info | `0x402` |

   R9 +0x500.. holds a second copy of the background/end-of-tile block
   with other offsets (`0x2900`/`0x2880`; meaning open).
3. **Texture descriptors** (diff `tex` against `vary2`, which has the
   same uv varying):
   - texels: 4x4 RGBA8 at R5+0x200 (0x1_0001c200), written by the
     Metal blit;
   - texture descriptor at R18 (0x1_00100000) +0: `1b44050a 00000600
     8000e100 00000000`; word 2 = texel address >> 1 (0x1_0001c200 >> 1
     = 0x8000e100). Word 3 is assumed to hold the address bits above
     (0 here: open). Words 0-1 hold format/size (not decoded yet; 4x4
     would be `(4-1)` fields: to vary in a capture);
   - sampler at R18+0x20: `000e0000 00c00780` (nearest, clamp: to vary);
   - the fragment PDS data (0x3c040 +0x20) holds both descriptor
     addresses, `00100000 00000001` (texture) and `00100020 00000001`
     (sampler), then `10000008` and `90010002` (DOUTD control words,
     Rogue layout: to decode);
   - `pvr-render-test` relocates descriptor word 2 like the image
     descriptors in R13. Without it the GPU fetches the unrelocated
     address and the fragment job hangs after half the tiles (1792
     clear, 256 triangle, 2048 untouched).

## Own programs (2026-10-31, `pvr-render-test OWN=…`)

**The triangle renders with every program it runs encoded by us** (TESTED,
`OWN=pds,bg,eot,vs FS_HALFFORM=1 FS_COLOR=0.5,0.25,1,1`: 3584 clear, 512
pixels `0xff8040ff`). Only the context store/resume PDS programs
(0x900/0xc40, run on a context switch) and the capture's state data
remain Apple's. Each `OWN` item replaces programs in place in the
capture's code heap, at the offsets the hardware takes from the record and
the stream:

| Item | Program | Where its offset comes from |
|---|---|---|
| `pds` | vertex kick: `DOUTW temps q0 → r0` (control `0x80000000` in data dword 2), `DOUTU` END+CC | VDM_STATE vs_pds_code / vs_pds_data (USC offset, 0x10) |
| `pds` | draw DMA: `DOUTD` END, data `{src, control}` | PDS_STATE code / data_addr |
| `pds` | fragment kick: `DOUTU` END at shader base + 0x20 | PPP PDS state pointer 0 (shader base: data {USC offset, 0x10}, code at +0x20) |
| `pds` | background: DMA (PDS_BGRND1) + kick (PDS_BGRND0 + 0x20) | record +0x280 |
| `pds` | end of tile: `DOUTD` of the 7-dword image state from data q0 (control `0x90000007`), `DOUTU` from data q2 | record +0x2b0 |
| `bg` | clear shader: 4 × f32 uniform → f16 half, `211c 0800`, `8000` | PDS_BGRND0's data dword 0 |
| `eot` | end-of-tile shader: r0 = 0, `051c 5100 0800` (PBE emit), jump to the end word | end-of-tile PDS data dword 4 |
| `vs` | vertex shader (below) | vertex kick data dword 0 |

The **PPP state is plain Rogue** (Mesa `csbgen/rogue/ppp.xml`; base
draw): `001c0000` (header: varying words 0-2) then VARYING0-2 (vary:
f32_linear 4, tex: 2); `000000c0` then SHADERBASE 0x1c0, TEXUNICODEBASE
0xc0 (HALT), SIZEINFO1 (vary `00800420`: uniform size 1, PDS varying 1,
USC varying 2), SIZEINFO2, VARYINGBASE 0x140 (HALT without varyings);
`00020000` OUTPUT_SEL (`04010000`: vertex size 4, rhw; vary 8);
`0000001f` ISPCTL `03c40000`, ISPA `003e0f00`, FB `0e000000`, BA
`00100f00`, BB 0; `00000c00` REGION_CLIP `80000001 1` and the viewport
(32 32 32 −32 0 1: a0 m0 a1 m1 a2 m2); `00210000` WCLAMP `1e3ce508`
(1e-20) and PPP_CTRL `4a0`; `00000020` ISPDBSC 0; `00c00000`
STREAM_OUT0-2 (`1`, `4022`, PDS data 0x30040: HALT); `02000000`
TERMINATE0/1 (`00040001 0`). tex adds `00000200` UNIFORMDATABASE 0x3c060
(the texture/sampler DMA). So Mesa's Rogue PPP/VDM emission applies as
is; only the programs are G9P's.

**DOUTD control word** (data dword after the source address; TESTED in
compute and here): bit 31 last, bit 28 common store, destination dword
<< 13, dword count in the low bits. Apple's draw DMA is `0x90000006`
(six floats of the vertex buffer into common-store dwords 0-5).

**Clear shader conversion** (TESTED): `018a 01hh 0101 01a0 01uu 4140
0104 00b0` writes half `hh` (W1 low bits, one f16 each: 4 halves = r0-r1)
from the f32 uniform `uu` = W4 `0x0101 | 4·dword`. `OWN=bg,bgswap`
(half h from uniform 3 − h) turns the black clear (0,0,0,1) into
`0x00ff0000`, as predicted.

**End of tile** (TESTED): Apple's shader moves common-store dword 6 of the
image state (`0188 0100 0199 4100 0128 0039`, 16-bit move form) into r0;
it is 0 in every capture, and a move-immediate of 0 works the same
(`OWN=eot` vs `eot,eotu6`). `051c 5100 0800` emits the tile through the
PBE with the image state in the common store; meaning of its fields still
open.

**Vertex shader** (TESTED): the vertex kick's DOUTW puts the **vertex
index in r0**. Ours reads the position from memory instead of Apple's
inline uniforms: our draw DMA writes the vertex buffer's address into
common-store dwords 0-1 (`{addr, 0x90000002}`), then

```
1189 0304 8181 4100 01a1 6600     r2:r3 = u0 + (r0 << 3)
2b10 0908 8800                    r4, r5 = *(r2:r3)   (2 x u32)
004d                              wait
0198 030c 0101 0120 0154 0038     r6 = 0.0
0198 030e 0101 8121 3f80 0154 0038  r7 = 1.0
151e 0108 0000  151e 010a 0001  151e 010c 0002   outputs 0-2 = r4, r5, r6
0100 01pp 0000, c000 padding      jump to the next 64-byte block
155e c10e 0003                    last output 3 = r7, in place of the end word
```

Outputs 0-3 are clip-space x, y, z, w (`OWN=vs,vsw2` with w = 2 halves
the triangle: 128 pixels instead of 512). The last output write takes the
end word's place at the start of a 64-byte block, as in Apple's shaders.

## A triangle from scratch (2026-10-31, `tools/pvr-tri.c`)

**`pvr-tri` renders the triangle with nothing captured** (TESTED: 3584
clear, 512 triangle pixels in about 2 ms, 200 of 200 runs; `TRI_CLEAR`,
`TRI_COLOR` and `TRI_W` change the output as predicted). It builds what
Mesa's G9P render path has to build:

- **Code heap**: one buffer mapped at both the PDS and the USC heap base.
  USC programs: fragment (two move-immediates of packed halves, `211c
  0800`, `8000`), vertex (above), clear, end of tile, and register 0x470's
  program (a jump to `015e a000`, as captured; meaning open). PDS
  programs: kick bundles (data `{USC offset, 0x10}`, code at +0x20) for
  the fragment shader, the background and 0x470; separate code/data for
  the vertex kick, the vertex-buffer DMA, the background DMA and the end
  of tile; HALT for the texture/uniform and varying programs, the context
  store/resume programs (never run without a context switch) and the
  stream-out program (data 16 bytes, HALT at +0x10).
- **Data**: the vertex buffer, its address for the common store, the
  clear colour (4 floats), the render target's image state (7 dwords),
  the PPP blocks and the VDM stream, two zeroed VDM context state
  buffers.
- **Image state** of the target: `0x0305050a | (w−1) << 27`, `(w−1) >> 5
  | (h−1) << 9`, address >> 1 with bit 63 set; the low 27 bits of dword 0
  (format BGRA8, twiddled) as captured. The 4x4 texture's descriptor has
  the same layout (`0x0344050a` base): width − 1 in bits 27-40, height − 1
  in bits 41-54. Rogue's TEXSTATE keeps the same fields higher (width at
  34), so this is an older layout; the format bits are still to decode.
- **VDM stream**: VDM_STATE (vertex PDS code, 4 outputs, `0x1081` USC
  sizes), PPP varying words, PDS_STATE (the DMA), VDM_STATE (vertex PDS
  data), the PPP blocks, INDEX_LIST (`6e440600 3 0 0 aa`: triangle list,
  3 vertices, no index buffer), PPP TERMINATE (clip (w/32−1) << 18 |
  (h/32−1)), STREAM_TERMINATE.
- **Registers** (job streams with the Apple extension, as
  `pvr-render-test`): the stream base, the context store/resume pairs
  `{sizes, code, data << 32 | sizes}` pointing at the HALT program, 0x470
  = the kick bundle, PDS_BGRND0-3 = `{dma code << 32 | kick bundle, 0,
  dma data, 0x0080000000800000}`, end-of-tile PDS code/data/info
  (`0x402`), and the constants the capture had.

Next: the graphics pipeline in Mesa (vertex/fragment compile in the G9P
backend, these programs generated per pipeline/render pass, Rogue
VDM/PPP emission, the Apple stream extension in the render job), then
varyings (DOUTI + iterate) and textures with our encodings.

## Varyings and textures with our encodings (2026-10-31, `pvr-tri TRI_VARY`, `TRI_TEX`)

**Varyings** (TESTED, two vec4 varyings, each read back on its own):

- Vertex side: outputs 0-3 position, then the varyings' components in
  order (slot 4 + component index); OUTPUT_SEL vertex size = 4 + all
  components; VDM_STATE vertex output dwords the same; PPP VARYING0
  f32_linear = the varyings' components.
- PDS (VARYINGBASE): the DOUTI data, padded to 16 bytes, then the code
  (one `DOUTI` per data pair, END on the last, HALT); SIZEINFO1's PDS
  varying size = that data in 16-byte units. Data: `03000000 0` (the W
  iterate), then per perspective-correct vecN varying at component offset
  c: word 0 = `03` | ((N−1) << 2 | 1) << 16 | L << 8 | L with L = 2 + 2c,
  word 1 = `0x00400000` | (c / 2) << 23 | last << 31.
- Fragment iterate `?308 03dd 0080` (f32 into r[dd/2]…; W0 bits 11-12 =
  N mod 4, corrected from 4 − N, see ISA.md "Fragment register bank"):
  **W1 bits 9-15 = 1 + the first component's index c** (sweep:
  field 1 reads varying 0, 2 its .y onwards, 5 varying 1's x). Apple's
  compiler also emits it without W2 (`0308 0200`) and with W2 `0x8000`
  for texture coordinates.
- USC varying size (SIZEINFO1 bits 4-9): 2 for one vec4 (captured), 4
  for two worked (not varied further).

**Textures** (TESTED, 4x4 RGBA8, nearest: the three sampled texels match
exactly):

- Texture state (8 dwords) and sampler (2 dwords) DMA'd into the fragment
  common store by the TEXUNICODEBASE program: `DOUTD q0` with control
  `0x10000008` (common store, dwords 0-7), `DOUTD q1` END with
  `0x90010002` (dwords 8-9), HALT; its data (UNIFORMDATABASE, PPP block
  `00000200 addr`) = {state address, sampler address, the two controls}.
  SIZEINFO1 uniform size 2, SIZEINFO2 `0x00800000` (USC shared size 1).
- Texture state: `0x0344050a | (w−1) << 27`, `(w−1) >> 5 | (h−1) << 9`,
  address >> 1 (dwords 2-3), 4 zero dwords. `0x0344050a` = RGBA8 (byte 0
  red), twiddled.
- **Texels are twiddled: Morton order with the y bit first**, as the
  render target. A linear upload samples (3,0) from stored index 10, i.e.
  linear (2,2): that is how the order was found.
- Sampler: `000e0000 00c00780` as captured (nearest; fields to decode).
- Fragment code: `1308 0300 8000` (iterate the vec2 coordinate into
  r0-r1), `f518 0100 8108 0700 0200` (sample with the state at
  common-store dword 0 and the sampler at 8, into the colour halves),
  `004d`, `211c 0800`, `8000`.

## The first Vulkan frame (2026-10-31, Mesa fork `4cb26a152ca`, `mesa/vk-tri`)

**`vk-tri` renders through Mesa's PowerVR driver on the A10**: dynamic
rendering into a 64x64 B8G8R8A8 image cleared to (0, 0, 0.25, 1), one
`vkCmdDraw` of a triangle with per-vertex colours from a vertex buffer
(GLSL `shaders/gfx/tri.{vert,frag}`). Output: 3584 clear pixels, 512
triangle pixels interpolating red, green and blue. The path
(`pvr_arch_g9p_gfx.c` in the fork) is `pvr-tri`'s, built from Vulkan
state: device programs once, pipeline programs per pipeline, the draw's
VDM/PPP words and DMA per draw, image state / end-of-tile / background
per render job, the job streams with the Apple block.

What it took beyond `pvr-tri` (each found by running Mesa's generated
code inside `pvr-tri`: `TRI_VS_HEX`, `TRI_FS_HEX`, `TRI_PDS_STATE0`,
`TRI_VDM5`):

- Vertex shader registers: VDM_STATE5 bits 10-15 (ISA.md "Register
  allocation").
- The draw's PDS_STATE0 common-store size: 1 hangs even when the shader
  reads only 8 bytes, 2 runs. Rogue's unit is 64 bytes; iPadOS uses 2
  for 24 bytes. Mesa uses 16-byte units, at least 2, until measured.
- The DRM winsys sends a partial-render fragment job with every render;
  the kernel's Apple path rejects those (`-EOPNOTSUPP`), so the G9P path
  leaves its stream empty and the winsys skips it.
- The kernel stream buffers (`fw_stream`, 64 / 440 bytes) are too small
  for the Apple block: 256 / 640.
- `G9P_DUMP=1` prints every program, PPP block, VDM word and job stream
  the driver builds; the format matches `pvr-tri`'s inputs.

Open (next): clearing tiles without geometry (a render with no draws only
clears the tile the background object happened to run on: the
empty-tile processing of "Resized render"), load ops other than clear,
depth, blending, culling from the pipeline, more vertex formats, uniform
buffers and textures in Mesa, presenting (WSI), then Zink.

## Render target captures (2026-10-31, `out/ios-render/{nodraw,linear,linear100,npot,screen,…}`)

Second capture batch (`capture.m` variants `nodraw` … `fubo`, one change
each from `base`). Decoded so far:

- **`nodraw`**: the stream is only the PPP terminate state and
  STREAM_TERMINATE; nothing else in the record changes. iPadOS clears
  empty tiles through a register: **ISP_CTL bit 17** (Rogue's
  `process_empty_tiles`). Without it, a render with no geometry clears
  only one tile, and a render with geometry only the tiles a primitive
  touched (TESTED, `pvr-tri TRI_NODRAW=1 TRI_ISP_CTL=23000f`: 4096 of
  4096 pixels; draws unaffected). The earlier "bit 17 does nothing"
  (kernel self-test, "Resized render") did not hold up through the UAPI.
- **`linear` / `linear100`** (texture over a buffer, 256 / 512-byte rows):
  the render target's image state changes its layout bits `0x0a` → `0x02`
  (dword 0), gains the row pitch in **64-byte units minus one at bit 111**
  (dword 3 bits 15+: 3 for 256 bytes, 7 for 512) and dword 5 =
  `0xc0000000`.
- **`npot`** (100x60, twiddled): the image state just holds the real size
  (width − 1 = 99, height − 1 = 59); the PPP terminate/region clip cover
  4x2 tiles, ISPCTL gains bit 16, and R16 holds (100, 60) (scissor
  table). Mesa renders 100x60 twiddled and linear correctly without the
  scissor so far.
- **`screen`** (1536x2048): only the sizes change in userspace memory
  (image state, terminate `00bc003f`, region clip, viewport); the record's
  size-dependent registers are kernel-filled.
- **Macrotiles**: RENDER.md's iOS 10 formula `m << 18 | m << 10 | 3m` for
  0xc08/0xc10 is really X1 = m (bit 18), X2 = 2m (bit 9), X3 = 3m: the
  kernel's (upstream) value equals the capture's `0x10100c` at 64x64.
- **ISP_RGN (0xf28) is size-dependent**: Rogue's "dwords to fetch from
  each region array", i.e. one macrotile's region headers: (tiles per
  macrotile) x 5 bytes / 4. iPadOS's `0x14` is 4x4 tiles; macrotiles grow
  to 8x8 tiles above 16 tiles (512 pixels), where a fixed `0x14` hangs
  every render (TESTED: 544x512 hung, fixed with the computed value;
  1536x2048 twiddled and linear render correctly).

With these, `mesa/vk-tri` renders 64x64 … 1536x2048, power-of-two or
not, twiddled or linear, and `TRI_FB=/dev/fb0` puts a 1536x2048 linear
frame on the iPad's screen (simpledrm framebuffer: 1536x2048, stride
6144 = the linear target's row pitch).

Still to decode from this batch: `rgba8`, `rgba16f`, `blend`, `cull`,
`depth`, `scissor`, `texfilter`, `texlinear`, `indexed`, `instanced`,
`fragcoord`, `discard`, `fubo`.

## Textures in Mesa (2026-10-31)

`vk-tri TRI_TEX=1|linear [TRI_FILTER=1]` samples a 4x4 RGBA8 texture
through a combined image sampler (GLSL `texture(t, v_col.xy)`), twiddled
or linear: exact texels with nearest filtering, blends with linear.

- **Sample instruction** (offline probes `tools/isa/probes/tex2.metal`,
  then `pvr-tri TRI_TEX_F32`): `f518` writes the result as the colour
  halves, `f51a` as f32 into r[dst]..r[dst+3] (W1 `0x0100 | 2·dst`).
  W2 = `0x8100 | state dword << 8 | sampler dword` (iPadOS's second
  texture: `0x8910`, state at 8, sampler at 16). Which texture/sampler is
  bound is only the driver's DMA: Metal shaders with texture(1) or
  sampler(1) compile to identical code.
- **Coordinates**: an iterate with W2 `0x8000` passes them straight to the
  sampler (exact and deterministic, with the varying declared vec2 or
  vec4). Otherwise the sample reads f32 r0-r1: Apple's code for
  `t.sample(s, v.uv * 2.0 + 0.25)` (`tex2.metal` `fs_math`) iterates into
  r0-r1 (`1308 0200`), computes on them (`019a 0100 …`, `019a 0102 …`)
  and issues the same sample word. Copying computed coordinates there
  first looked non-deterministic, before the fragment register bank was
  known (ISA.md); with fragment-bank moves it works (Mesa, vk-tri
  `texc*.frag` checks, 2026-11-01). W1 high bits as a register field
  failed in every form tried.
- **Texture state**: the render-target image-state layout (format bytes
  1-2: BGRA8 `0505`, RGBA8 `4405`, RGBA16F `4446`; layout `0x0a`
  twiddled / `0x02` linear with the row pitch in 64-byte units at bit
  111, `texlinear` capture); 4 zero dwords after it.
- **Sampler**: nearest/clamp `000e0000 00c00780`; dword 0 bit 23 makes
  magnification linear (TESTED: 10 → 387 distinct colours). iPadOS's
  linear+repeat (`texfilter` capture) also sets dword 0 bits 25 and 29
  and dword 1 bit 0: minification and the U/V wrap modes, not separated
  yet (the test magnifies and stays within 0..1). Separated on hardware
  on 2026-11-01 (MESA.md "Resize glitch"): bit 25 minification, bit 29
  U repeat, dword 1 bit 0 V repeat.
- **Fragment common store**: texture t's state at dword 16t, its sampler
  at 16t + 8, DMA'd per draw by a TEXUNICODEBASE program (three DOUTDs
  per texture: state, zeros, sampler) whose data UNIFORMDATABASE points
  at; SIZEINFO1 uniform size = that data in 16-byte units, SIZEINFO2 USC
  shared size = the common store in 64-byte units.

Other decodings of the second batch: **culling** is PPP_CTRL bits 0-1
(`cull` with front faces culled: `0x4a0` → `0x4a1`); **scissor** sets
ISPCTL bit 16 and a scissor table entry `{left << 16 | right, top << 16 |
bottom}` (`00080030` for 8..48); **blending** marks ISPA/BA pass type 1
(translucent) and is done by the fragment shader: `211c 2800` reads the
tile's colour into r0-r1 as halves, then f16 multiply-adds (operand form
of the half sources still to decode).
