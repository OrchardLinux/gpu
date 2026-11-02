# Mesa on the A10 GPU (G9P): bring-up guide, Vulkan driver part

Written 2026-11-01 against the Mesa fork
the Mesa fork (OrchardLinux/mesa), branch `main`, at `b9721ab4b49`
(upstream base `801952de2f1`), and the lab notes in
`a10/` (MESA.md, RENDER.md, ISA.md, COMPUTE.md, REFERENCE.md,
PDS-OFFLINE.md). The notes are chronological; where they disagree with each
other or with the code, this guide follows the code and lists the
disagreement under "Conflicts" at the end.

Who this is for:

- whoever brings up the A9 (S8000/S8003) GPU on the same stack;
- whoever ports the driver to another Apple SoC with a PowerVR-derived GPU.

What you need to know already: Vulkan basics and the general idea of a GPU
driver (command buffers, shaders, render passes). PowerVR internals and
Apple's variant are explained below.

The fork is private. Every commit carries `Generated-by: LLM`, and nothing
from it goes to Mesa's GitLab (MESA.md "Decisions").

Each fact below uses the same layout:

- **What**: what is true.
- **Evidence**: the capture, measurement or commit behind it.
- **Code**: where it lives (`file:function`; paths under `src/imagination/`).
- **Verify**: how to check it on new hardware.
- **A9**: likely the same, likely different, or unknown and what to check.

"Inference" marks anything not measured directly.

---

## 1. Concepts primer

### 1.1 Tile-based deferred rendering (TBDR)

PowerVR GPUs don't draw triangles straight into the framebuffer. A render
runs in two jobs:

1. **Geometry job** (Imagination calls this "TA", tile accelerator; Rogue
   also uses VDM/PPP/TE). It runs the vertex shaders, clips and culls, and
   *bins* each primitive into the screen tiles it touches (32x32 pixels on
   the A10). The binned primitive lists go into the **parameter buffer**.
2. **Fragment job** (the "3D" job, also ISP/TSP/PBE). It walks the tiles
   one at a time. For each tile, the ISP (image synthesis processor) does
   hidden-surface removal on the tile's primitives, the fragment shaders run
   on on-chip tile memory, and at the end the PBE (pixel back end) writes
   the finished tile to memory.

So a render's cost scales with how many tiles it touches and how much
geometry it bins. Both facts matter for the optimizations in section 3.

### 1.2 Parameter buffer, free list, parameter manager

The parameter buffer is GPU memory for the binned geometry. The kernel
hands it to the firmware as a **free list**, a stack of page numbers. The
**parameter manager (PM)** takes pages during the geometry job and gives
them back when the fragment job has consumed them. On Rogue, when the free
list runs out mid-scene, the hardware does a **partial render**: it renders
what has been binned so far (and stores it, the SPM path, "smart parameter
management"), frees the pages, and resumes binning.

### 1.3 Control streams

- **VDM** (vertex data master) control stream: the per-draw words a
  geometry job walks through (state, index list, terminate).
- **PPP** (primitive pre-processor) state blocks: per-draw ISP, viewport,
  region clip, varyings and shader pointers, referenced from the VDM
  stream.
- **CDM** (compute data master): the compute equivalent, one record per
  dispatch.
- The kernel also receives a **firmware stream** per job: register values
  the firmware programs before it kicks the job. On the A10 that stream
  carries an Apple-specific extension block (section 3.1).

### 1.4 PDS programs

The **PDS** (programmable data sequencer) is a small processor that runs
before every shader task. Its programs DMA data into the shader's **common
store** (shared, per-task uniform storage, think of it as push constants
the hardware loads) and kick the shader with DOUT instructions: DOUTD (DMA),
DOUTW (write a value), DOUTU (start the USC task), DOUTI (issue varying
iteration). Every draw, background, end-of-tile and dispatch starts with a
PDS program.

### 1.5 USC shaders

The **USC** (unified shading cluster) runs vertex, fragment and compute
shaders. On Rogue its ISA is Imagination's, compiled by Mesa's `pco`. On the
A10 it is not (1.8).

### 1.6 Background object, end-of-tile program

- **Background object**: a full-tile "draw" the fragment job runs on each
  tile before the real geometry, to initialize the tile. That is where load
  ops happen: a clear writes a constant, a load reads the old contents.
- **End-of-tile (EOT) program**: runs after each tile and emits it through
  the PBE to memory. Its input is an **image state** (the target's format,
  size, layout and address).

### 1.7 ISP control, region clip, scissor table

- **ISP_CTL** (register 0xf38) is per render. Its bit 17 is Rogue's
  `process_empty_tiles`: when set, the background object and EOT also run
  on tiles no primitive touched.
- **Region clip** (PPP block): a rectangle in tile units. The tiler bins
  the draw only into tiles inside it.
- **Scissor table**: a per-render array of pixel rectangles. A draw selects
  one by index, and the PPP ISP control word's bit 16 enables it.

### 1.8 How the A10 differs from upstream Rogue

- **What**: the A10 (T8010, CORE_ID `0x011b0602`, CORE_REVISION
  `0x000d0a00`) pairs Rogue fixed-function hardware with Apple's own shader
  core. These parts stay Rogue: the PDS instruction set (HALT, DOUTD/W/U/I,
  END bit 26, CC bit 27), CDM/VDM/PPP control streams (with Apple
  additions), and the MMU page tables (PC/PD/PT). The USC ISA is Apple's
  (`applegpu_g9p`). It doesn't parse as Rogue instruction groups: there are
  no end groups, code is 16-bit granular, padded with `0xc000` and ended by
  `0x8000` at the start of a 64-byte block.
- **Evidence**: REFERENCE.md "Shader ISA: Apple, not Rogue". iPadOS's
  loaded shaders are byte-identical to `metal-tt -arch applegpu_g9p`
  output. RENDER.md "Own programs": every PDS program of a triangle
  re-encoded by us, with PPP state "plain Rogue (`csbgen/rogue/ppp.xml`)".
- **Code**: the device is `common/device_info/apple-a10.h` (BVNC 13.10.6.2;
  only the values marked "A10" are measured, the rest are GX6650
  placeholders). The feature `has_apple_g9p` gates every difference
  (`common/pvr_device_info.h`). It's a runtime feature, not a second
  `PVR_DEVICE_ARCH` (MESA.md "Decisions").
- **Verify**: compile a trivial Metal kernel with the toolchain for your
  SoC and check that the output ends in `8000` after `c000` padding
  (ISA.md "Method"). Capture a render on iOS (`ios-capture/`) and match
  the PDS words against Mesa's `pvr_rogue_pds_defs.h`.
- **A9**: unknown, check. The A9's GPU is also PowerVR-derived, but whether
  its shader core is Apple's ISA, Rogue USC or something in between has to
  be established the same way: compile with the Metal toolchain's A9 target
  (look up the `-arch` name `metal-tt` accepts, don't assume one) and look
  for the same word structure.

### 1.9 Why upstream `pco` can't be used for shaders

- **What**: `pco` emits Rogue USC instruction groups. The A10 executes
  Apple's encoding, so every shader (application and driver-internal: EOT,
  clear, load, SPM) has to come from a different compiler. The fork's
  `g9p/g9p_compile.c` replaces `pco` on G9P. PDS generation (`vulkan/pds/`,
  `pdsc/`) and control-stream packing (`csbgen/`) stay reusable, though the
  A10's DOUT field layout differs from Mesa's encoder (bits 0-2 type, 3-7
  64-bit source, 8-9 source space, 10-15 control dword: COMPUTE.md "Apple
  PDS DOUT encoding"), so G9P has its own `g9p_pds_dout()` in
  `g9p/g9p_cdm.h`.
- **Evidence**: REFERENCE.md "Mesa" table; COMPUTE.md.
- **Code**: `vulkan/pvr_arch_pipeline.c:pvr_graphics_pipeline_compile`,
  `pvr_compute_pipeline_init` (gated early returns into
  `pvr_arch_g9p_*_pipeline_compile`).
- **A9**: the shared-code bypasses in section 4 carry over whatever the ISA
  turns out to be. Whether `g9p_compile.c` can be reused depends on 1.8.

### 1.10 Zink

Zink is Mesa's OpenGL implementation on top of Vulkan. Hyprland (the
compositor) and its clients speak GL ES, Zink turns that into Vulkan calls on
this driver. So every Zink habit (dynamic rendering, extended dynamic state,
BGRA through swizzled views, CPU-visible transfers) becomes a driver
requirement. See section 6.

---

## 2. The G9P compiler

### 2.1 Pipeline: SPIR-V to NIR to Apple ISA

- **What**: `vk_pipeline_shader_stage_to_nir()` with `g9p_spirv_options()`
  and `g9p_nir_options()` gives NIR. Then:
  - `lower_front()`: inline everything, globals to locals, indirect local
    arrays to if-trees, explicit IO for buffers, `zero_descriptor_offset`.
  - `lower_io()`.
  - For fragment shaders: `discards_to_if`, `discards_to_flag`, the blend
    path and `lower_fb_fetch_instr`.
  - `compile_back()`: optimize, scalarize, `rematerialize_loads` (cheap
    loads repeated per using block), `nir_opt_move`, out of SSA, liveness,
    then `generate()` emits words through the encoders in `g9p/g9p_isa.h`.
    Control flow runs on an execution-mask stack kept in the register after
    the program's own.
- **Evidence**: commits `8cee4b12ea5` (compute), `d91427625ff` (control
  flow), `8d3796eb233` (transcendentals), `4cb26a152ca` (vertex/fragment),
  `5208bab21cf` (fragment register bank).
- **Code**: `g9p/g9p_compile.c:g9p_compile_compute`, `g9p_compile_vertex`,
  `g9p_compile_fragment`, `compile_back`, `generate`; encoders in
  `g9p/g9p_isa.h`, which mirror `tools/isa/g9p.py`.
- **Verify**: `mesa/vk-compute-test` (12 compute shaders),
  `mesa/fsops.py` (15 groups of fragment ops through `vk-tri TRI_FS_SPV`),
  `mesa/vk-suite.sh`.
- **A9**: the NIR-side structure likely carries over. The encoders don't
  unless the ISA matches.

Hardware rules the compiler follows (all tested on the A10, ISA.md):

- Instruction length: bit 8 of every 16-bit word means "another word
  follows".
- Jump offsets keep offset bit 8 in bit 0. Splitting them wrong made jumps
  of 256 bytes or more land wrong and hang (`d91427625ff`).
- Apple's select/move pair (`g9p_sel`/`g9p_movf`) hangs the GPU while lanes
  are masked off. Selects are predicated copies instead
  (`g9p_compile.c:emit_select`).
- **Fragment register bank**: fragment code clears W0 bits 11-13 and W1
  bit 9 (`0199 01dd`). Compute and vertex code sets them (`3199 03dd`). With
  the wrong bank, fragment results land in registers nothing reads
  (`g9p_isa.h:g9p_w0`, `g9p_dst`; ISA.md "Fragment register bank").
- An iterate's component count is W0 bits 11-12 = count mod 4, not
  4 - count. Non-perspective iterates don't count the W component.
- The vertex index arrives in r0. Vertex shader registers are allocated by
  VDM_STATE5 bits 10-15 (units of 2), not by the kick's DOUTU temps. The
  fragment/compute DOUTU temp count is `DIV_ROUND_UP(regs, 4) << 3`
  (`pvr_arch_g9p_gfx.c:usc_temps`). Compute register allocation is CDM K0
  bits 12-17 (COMPUTE.md "Register allocation").
- Vertex attributes are plain memory loads at the vertex index. Only 32-bit
  components are accepted (`pvr_arch_g9p_gfx.c:attrib_format_ok`).
- **A9**: every encoding rule here is A10-measured. Re-derive each one with
  the probe method (ISA.md "Method": vary one operand per power of two).

### 2.2 Register limits: r0-r31, homes up to r127

- **What**: the 5-bit register fields reach r31. Values get r0-r29
  (`G9P_NUM_REGS` = 30), the mask stack goes after the highest used
  register, and a graphics task gets 32 registers in these forms. Fragment
  tasks can address r0-r127:
  - as a destination, the usual `0x0100 | 2r`;
  - as a source, the operand word holds `r & 31` with bit 0 set, plus an
    extension word holding `r >> 5` (first operand at bit 1, second at
    bit 9). That's the same form as uniform operands.

  When generation runs out of registers in a fragment shader,
  `compile_back()` gives the live NIR register with the furthest last use
  (else an SSA value) a "home" above r31 and regenerates. The value is
  stored after each definition (`g9p_mov_to_high`, an OR) and reloaded into
  a temporary for each use (`g9p_mov_from_high`). There are up to 96 homes,
  and the task's temp count covers them (`out->num_regs`). Vertex and
  compute shaders have no homes: they fail with "out of registers".
- **Evidence**: commit `d1ab45daed3`. ISA.md "Registers above r31" (r40,
  r77, r100 written and read back in `pvr-tri`). Apple's compiler uses up to
  r101 in fragment code. `press*.frag` tests (56-118 registers) are exact in
  vk-tri.
- **Code**: `g9p_compile.c:compile_back` (the retry loop), `park_def`,
  `src_reg`; `g9p_isa.h:g9p_mov_to_high`, `g9p_mov_from_high`.
- **Verify**: `vk-tri` with a pressure shader, plus `G9P_REGS=N` to force
  spilling at a lower count (debug override, capped at 63).
- **A9**: likely different in encoding details (register file size,
  extension word). Check the highest register Apple's A9 compiler uses in a
  large fragment shader.

### 2.3 FMA fusion and the ffma addend kill-bit fix

- **What**:
  - NIR's `float_mul_add32` used to be 0, so NIR split every ffma into
    fmul + fadd. It is now `has_ffma | fuse`.
  - The ffma encoder put the addend in a third operand word
    `0x0180 | c << 2`. Bit 7 of an operand word is the **last-use (kill)
    flag** (as in `g9p_srcs()`, `0x8080`), so every ffma declared its
    addend dead. That was harmless while ffmas were rare, but fused code
    reuses addends and broke. The word is now `0x0100 | c << 2`.
- **Evidence**:
  - `28cdfceab8e`: a shader of 512 multiply-adds went from 15.4 to 12.4 KB,
    8.9 to 6.6 ms over 393216 pixels.
  - `906f3eab2a6`: Hyprland's blur with vibrancy showed red and cyan blocks
    in every other frame before the fix, and none in 24 grabbed frames
    after it.
- **Code**: `g9p_compile.c` `nir_options.float_mul_add32`;
  `g9p_isa.h:g9p_ffma`.
- **Verify**: run any shader that reuses an ffma addend later (HSL math)
  and compare against a CPU reference.
- **Inference**: `g9p_isa.h:g9p_sel` and `g9p_movf` still build a third
  operand word `0x0180 | x << 2`. They are unused today (2.1). If you revive
  them, check that bit first.
- **A9**: the lesson (last-use bits in operand words) likely carries over.
  The bit position is unknown, check with the probe method.

### 2.4 Discard in blending shaders: discard becomes select

- **What**: in a shader that reads the tile (blending, pass type 1
  translucent), the hardware discard (`6004`) dropped pixels in random 32x32
  tiles whenever other objects shared the tile. For such shaders,
  `discards_to_select()` removes the discards and moves every colour store
  to the end, `bcsel(any_discard, tile_value, colour)`. With native
  source-over blending (3.8) the "tile value" is transparent black, which
  the blend turns into "keep the tile". Shaders with discards or colour
  stores inside control flow keep the hardware discard. Opaque discarding
  shaders use pass type 4 (punch-through) and are unchanged. Discards nested
  in control flow first become a flag and one `demote_if` at the end
  (`discards_to_flag`); after a "discard" those pixels run on, which only
  matters for side effects.
- **Evidence**: commit `7013b551398`; MESA.md "Window borders" (synchronisation,
  common store, other draws and temp count all ruled out on the device).
- **Code**: `g9p_compile.c:discards_to_if`, `discards_to_flag`,
  `discards_to_select`, `g9p_compile_fragment`; pass type selection in
  `pvr_arch_g9p_gfx.c:emit_draw` (PPP block 3).
- **Verify**: Hyprland's border shader. Judge by whole columns of tiles
  over several frames, not one pixel row (MESA.md "CPU transfers",
  lesson).
- **A9**: unknown. It's a hardware behaviour of the translucent pass, so
  test the same draw in a full scene before trusting a hardware discard
  there.

### 2.5 Other compiler limits that bite

- Fragment memory loads don't work yet: the A10 form hangs, the compute
  form reads zeros. Uniform buffers and push constants are DMA'd into the
  fragment common store (buffer k's first up to 128 dwords at dword
  `16 + 128k`) and read as uniform operands, so only constant offsets below
  512 bytes compile (`g9p_compile.c:emit_mem`; ISA.md "Fragment uniforms and
  loads").
- One texture per fragment shader (`texture_slot`). The texture state sits
  at common-store dword 0 and the sampler at 8. The header notes that only
  state at dword 0 samples correctly so far (`g9p_compile.h`).
- `gl_FragCoord` comes from an extra varying the vertex shader writes
  (`add_frag_coord_output`), iterated without perspective, because the
  position read's 16-bit result isn't decoded for f32 use.
- f16 to f32 from the tile is done in integer code (exact for unorm),
  because Apple's half-to-f32 conversion only wrote r0-r2 in tests
  (`lower_fb_fetch_instr`).
- Not done: depth/stencil, MSAA, more than one colour attachment, blend
  constants, indirect draws, non-32-bit vertex formats.

### 2.6 Known costs of Hyprland's border and shadow shaders

- **What**: these two shaders dominate composite fragment time.
  - Border shader: two `vec4[10]` gradient arrays from 40 uniform loads,
    read through if-ladders. It compiled to 116 registers and 22 KB
    (`d1ab45daed3`, test config); in the effects demo, MESA.md gives 30 KB
    and 123 registers.
  - Shadow shader: 23 KB, 118 registers.
  - Both are about 1000 and 840 NIR operations with 70 branches each, and
    both cover each window's whole box.

  Static three-window scene, composite fragment time: all effects 47 ms, no
  shadow 27, also no border 11.5, also no rounding 4.1.
- **Evidence**: MESA.md "The effects demo" (`G9P_SYNC=1 G9P_TIME=1`).
- **Code**: dump with `G9P_DEBUG=1` (prints registers and code size per
  shader).
- **Verify**: same measurement on your SoC. Compare against Apple's
  compiler output for an equivalent Metal shader to see how far off the
  backend is (the Julia effect was about 2x behind, MESA.md).
- **A9**: likely the same shader workload (same Hyprland). Costs differ
  with clock and core count.

---

## 3. Command streams and jobs

### 3.1 Job streams with the Apple block

- **What**: the geometry and fragment firmware streams the kernel takes are
  Rogue's fields followed by an Apple extension header
  (`G9P_EXTHDR_APPLE` = bit 29 | 1) and an Apple register block.
  - Geometry: VDM stream base, PPP_CTRL 2, TE_PSG (bit 17 on terminate),
    0xc90 = `0x1e3ce508`, two VDM context state buffers, context
    store/resume PDS pairs pointing at HALT (they only run on a context
    switch), register 0x470's program (a jump to `015e a000`, meaning open),
    six zeroed cluster words, 0xc78 = 0x88.
  - Fragment: the scissor table base, zero PBE and Rogue background words
    (in the extension instead), ISP_BGOBJDEPTH 1.0, ISP_BGOBJVALS 0x300,
    ISP_CTL (3.4), EVENT_PIXEL_PDS_INFO 0x402 and the EOT data, then in the
    Apple block: sample positions 0x88, PDS_BGRND0-3 (3.5), per-cluster
    words, EOT code, ISP_RGN, constants, line-rasterization scales
    (tan 15°/size, tan 60°/size, 16 x width).
- **Evidence**: RENDER.md "First rendered triangle" (register table), "A
  triangle from scratch" (`tools/pvr-tri.c`). Commit `4cb26a152ca`.
- **Code**: `vulkan/pvr_arch_g9p_gfx.c:g9p_geom_stream`, `g9p_frag_stream`;
  called from `pvr_arch_job_render.c:pvr_render_job_ws_geometry_state_init`
  / `pvr_render_job_ws_fragment_state_init` when `job->g9p.enabled`.
  `winsys/pvr_winsys.h` stream buffers grow to 256/640 bytes.
- **Verify**: `G9P_DUMP=1` prints both streams; compare with `pvr-tri`'s
  inputs and an iOS capture.
- **A9**: likely different values (kernel- and firmware-specific), likely
  the same structure if the kernel's Apple path is shared. Check against an
  A9 iOS capture.

### 3.2 Draw contents

- **What**: per draw (`emit_draw`), in this order:
  1. VDM_STATE (vertex PDS code, output dwords, VDM_STATE5 register count);
  2. PPP varying block;
  3. VDMCTRL_PDS_STATE0 with the vertex-buffer DMA. Its common-store size
     unit is not Rogue's 64 bytes: 1 hangs and 2 runs, so it's 16-byte units,
     at least 2;
  4. vertex PDS data;
  5. PPP blocks: varying words, PDS pointers (shader base,
     TEXUNICODEBASE program, SIZEINFO1/2 with bit 14 for discard), the
     UNIFORMDATABASE pointer, OUTPUT_SEL, ISP control (pass type: 1
     translucent when the shader reads the tile, 4 punch-through when it
     discards, else 0), region clip + viewport, WCLAMP/PPP_CTRL, scissor
     index, stream-out;
  6. INDEX_LIST.

  All of a draw's words sit between `pvr_csb_set_relocation_mark()` and
  the clear call, so a draw moves whole into the next control-stream
  buffer.
- **Evidence**: RENDER.md "Own programs" (PPP state plain Rogue), "The
  first Vulkan frame". `06f246344a6` (about 150 draws asserted in
  `pvr_csb_buffer_extend()` before the mark).
- **Code**: `pvr_arch_g9p_gfx.c:g9p_cmd_draw`, `emit_draw`,
  `upload_vs_uniforms`, `upload_textures`, `upload_varyings`.
- **Verify**: `vk-tri TRI_DRAWS=1000`, `TRI_INSTANCES`, `TRI_STRIP`.
- **A9**: PPP/VDM likely the same Rogue layout. The PDS_STATE0 size unit
  and VDM_STATE5 register field may differ, so measure them as above.

### 3.3 Scissor table and region clip

- **What**: each draw's scissor, clamped to the render area, becomes an
  entry `{left << 16 | right, top << 16 | bottom}` (right and bottom
  exclusive) in the render's scissor table (Rogue's `scissor_array`, an
  equal neighbour is reused). Its index goes into PPP ISPDBSC, and ISP
  control bit 16 enables it. The fragment stream carries the table base.
  The same rectangle in 32-pixel tiles is the draw's **region clip**, so
  the tiler bins the draw only into those tiles. A draw whose scissor is
  empty is dropped.
- **Evidence**: RENDER.md "Render target captures" (`npot`, `scissor`
  captures). Commits `47c5ed2f74b`, `42f87aff113`.
- **Code**: `pvr_arch_g9p_gfx.c:scissor_index`, `g9p_cmd_draw` (region),
  `emit_draw` PPP blocks 4 and 6.
- **Inference**: a region of all zeros means "whole render area" in
  `emit_draw`. A scissor inside tile (0,0) alone also yields all zeros, so
  it's binned into every tile. That's correct, just not skipped.
- **Verify**: `vk-tri` scissor and full-screen checks; Hyprland
  damage-scissored redraws.
- **A9**: likely the same (Rogue PPP). Check the scissor entry format with
  a capture.

### 3.4 ISP_CTL process_empty_tiles (bit 17) and tile skipping

- **What**: with ISP_CTL bit 17 set (`0x23000f`), the background object and
  EOT run on every tile. With it clear (`0x21000f`), only on tiles some
  draw's region clip reached. Rules:
  - **Cleared renders must set it.** Otherwise the clear reaches only
    tiles a primitive touched (a render with no draws clears one tile).
  - **Loaded renders clear it.** Untouched tiles are neither loaded nor
    stored, so they keep their memory, which is what the load gives them
    anyway.
  - **Don't-care renders** (no colour init in the render setup,
    `G9P_LOAD_OP_NONE`) clear it too: their old contents are undefined.
  - `G9P_ALL_TILES=1` forces bit 17 on.
- **Evidence**:
  - RENDER.md "Render target captures" (`nodraw` capture;
    `pvr-tri TRI_NODRAW=1 TRI_ISP_CTL=23000f` gives 4096 of 4096 pixels).
  - `42f87aff113`: loaded renders took 0.7-2 ms instead of about 3 ms.
  - `b15b5418b76` (don't care). MESA.md "Live blur": Hyprland's blur renders
    are whole-screen with clear or don't-care load ops and draw 1-27% of it,
    so the clear ones must keep every tile; the don't-care change "changed
    little".
- **Code**: `pvr_arch_g9p_gfx.c:g9p_frag_stream` (the `ISP_CTL` word),
  `g9p_job_init` (`job->g9p.load`, `load_op`).
- **Verify**: `vk-tri` load, scissor and full-screen checks with and
  without `G9P_ALL_TILES=1`. `G9P_TRACE` shows each render's load op and
  covered tiles.
- **A9**: likely the same (Rogue register). Verify the `nodraw` behaviour
  first, since an early kernel self-test wrongly suggested bit 17 did
  nothing (RENDER.md "Resized render", corrected later).

### 3.5 Background object: clear and load

- **What**: PDS_BGRND0 = `{DMA code << 32 | kick bundle}`, BGRND2 = the
  DMA's data, BGRND3 = `0x0080000000800000`.
  - **Clear**: the DMA puts the clear colour (4 floats) into common-store
    dwords 0-3. The clear shader converts each float to a half of r0-r1 and
    outputs it.
  - **Load**: iPadOS's `load` capture, reproduced. The shader reads the
    pixel position (`211c 6800`, x and y as u16 in 1/16 pixels), converts
    with u2f, multiplies by `1/(16 * size)` (common-store dwords 12-13) and
    samples the target itself (texture state at dword 0, nearest/clamp
    sampler at 8) into the colour halves.
  - Load ops other than load and clear clear to transparent black.
- **Evidence**: RENDER.md "Own programs" (clear shader `018a 01hh ...`).
  Commit `47c5ed2f74b` (Hyprland's damage-only frames kept the rest).
- **Code**: `pvr_arch_g9p_gfx.c:g9p_gfx_device_init` (`clear_usc`,
  `load_usc`), `g9p_job_init`.
- **Known gap**: `vk-tri TRI_LOAD=3` (a load after a clear-only pass) fails
  (MESA.md "CPU transfers").
- **A9**: likely the same mechanism. Encodings follow 1.8.

### 3.6 End-of-tile program and image state

- **What**: the EOT PDS DMAs the 7-dword image state into the common store
  and kicks a shader: r0 = 0, then `051c 5100 0800` emits the tile through
  the PBE. Image state, dwords:
  - 0: `0x03000000 | format << 8 | layout | (w-1) << 27`. Format bytes:
    BGRA8 `0505`, RGBA8 `4405`, RGBA16F `4446`. Layout `0x0a` twiddled,
    `0x02` linear.
  - 1: `(w-1) >> 5 | (h-1) << 9`.
  - 2-3: address >> 1, with bit 63 set for render targets.
  - Linear targets add the row pitch in 64-byte units minus one at bit 111,
    and dword 5 = `0xc0000000`.

  Hence the PBE stride alignment of 16 pixels (`pvr_image.c:get_pbe_stride_align`).
  Unknown formats fall back to BGRA8 with a warning.
- **Evidence**: RENDER.md "A triangle from scratch", "Render target
  captures" (`linear`, `linear100`, `npot`, `screen`).
- **Code**: `pvr_arch_g9p_gfx.c:pack_image_state`, `image_format_bits`,
  `g9p_job_init`.
- **Verify**: render 64x64 to 1536x2048, power-of-two and not, twiddled
  and linear (`vk-tri`), and check `TRI_FB=/dev/fb0`.
- **A9**: unknown. RENDER.md notes this is an older layout than Rogue's
  TEXSTATE (width at bit 27, not 34), so check the A9's against a capture.

### 3.7 Twiddling, textures, BGRA swizzle

- **What**:
  - Twiddled surfaces are Morton order **with the y bit first**, over the
    power-of-two padded size.
  - Texture state is the render-target layout (dwords 0-3, then 4 zero
    dwords), written into the view's sample descriptor at
    `vkCreateImageView`. Samplers are `000e0000 00c00780`
    (nearest/clamp); dword 0 bit 23 makes magnification linear, bit 25
    minification, bit 29 repeats u and dword 1 bit 0 repeats v (TESTED with
    vk-tri `TRI_VCOL` past 1 and `TRI_WRAP=repeat`). Until 2026-11-01 bit
    25 and dword 1 bit 0 were swapped: every linear-filtered texture then
    repeated vertically, which Hyprland shows as a window's content twice
    while it resizes (`render:expand_undersized_textures` samples past the
    buffer's edge and needs clamping). Mirrored and border modes are not
    decoded and clamp.
  - Zink samples GL's BGRA textures through RGBA8 views swizzled B,G,R,A.
    For 8-bit RGBA/BGRA the swap becomes the other byte order's format
    code. Other swizzles are logged, not decoded, and alpha ONE reads the
    stored alpha.
  - CPU copies to and from twiddled images use per-copy column/row offset
    tables.
- **Evidence**: RENDER.md "Varyings and textures with our encodings",
  "Textures in Mesa". Commits `2f09119a9bc` (swap), `89b19a3b464` (1536x2048
  upload 88 ms to 9-17 ms; 1448x966 40 ms to 4-5 ms).
- **Code**: `pvr_arch_g9p_gfx.c:g9p_pack_image_view`, `g9p_pack_sampler`
  (called from `pvr_arch_image.c:CreateImageView`,
  `pvr_arch_sampler.c:CreateSampler`); `pvr_arch_g9p_transfer.c`.
- **Verify**: a 4x4 texture with distinct texels sampled at each texel; a
  checkerboard wallpaper (`mesa/test-wallpaper.py`) shows swaps and edges.
- **Known gap**: linear non-power-of-two textures fail
  (`vk-tri TRI_TEX=linear TRI_TEX_SIZE=300x200`).
- **A9**: twiddle order likely the same (inference), format codes unknown.

### 3.8 Blending is shader code; native premultiplied source-over

- **What**: Apple's GPU has no fixed-function blender. The fragment shader
  reads the tile (`211c 2800 | h`) and blends, and the draw is marked
  translucent (pass type 1). The general path is `nir_lower_blend` in f32,
  about 40 instructions per pixel. For premultiplied source-over on all four
  channels (`ONE, ONE_MINUS_SRC_ALPHA`, the usual blend for Hyprland and
  Zink), the shader instead ends with Apple's own 7-instruction f16
  sequence: tile into halves 4-7, `1 - alpha`, four half multiply-adds.
  `G9P_NO_NATIVE_BLEND=1` restores the general path.
- **Evidence**: ISA.md "Tile read and blending". Commit `0ca35c1de72`
  (`vk-tri TRI_BLEND=1 ... TRI_WANT=0xff4080df` exact). `7a64e1d1bf4`:
  composite render 13.7 to 5.0 ms fragment time.
- **Code**: `pvr_arch_g9p_gfx.c:blend_options`;
  `g9p_compile.c:is_src_over`, `g9p_compile_fragment`, `generate`;
  `g9p_isa.h:g9p_blend_src_over`, `g9p_tile_read`.
- **Verify**: `explore-blend.py` (ISA.md) prints Apple's sequence for any
  blend state on your target; compare with the encoder.
- **A9**: unknown whether the A9 also blends in the shader. Check a
  `blend` vs `base` iOS capture: on the A10 they differ only in the shader
  and the pass type.

### 3.9 Free list size stopgap; partial renders (open)

- **What**:
  - The Apple firmware takes a render's *local* free list as its whole
    parameter buffer. It never grows it and reloads it only when the
    command's free-list index changes, which the kernel keeps at 0. So every
    render-target dataset shares one device-wide list of
    `G9P_FREE_LIST_SIZE` = 32 MiB (compile-time; one per Vulkan device,
    so one per process).
  - The A10's geometry microsequence has no out-of-memory branch
    (StartTA, Wait(TA_FINISHED | TA_TERMINATE | PM_OUT_OF_MEMORY),
    FinalizeTA, End). A scene that outgrows the list hangs the GPU until
    reboot.
  - Partial renders aren't implemented: the kernel's Apple path rejects the
    partial-render job, so Mesa leaves its stream empty and the winsys
    submits one job fewer.
- **Evidence**:
  - `73cb8c5669a`: at the minimum size two draws with their own state, or
    32 instances, hung. (Instanced hangs at any list size turned out to
    be VDM_STATE5 MAX_INSTANCES: MESA.md "Instanced draws and the
    geometry hang".)
  - `4ac3eedab44`: at 8 MiB 3000 draws of an eighth of 1536x2048 hung; at
    32 MiB 3000 and 6000 pass.
  - MESA.md "Two hangs, not one".
- **Code**: `pvr_g9p.h:G9P_FREE_LIST_SIZE`;
  `pvr_arch_g9p.c:g9p_device_init`;
  `pvr_arch_job_render.c:pvr_arch_render_target_dataset_create`,
  `pvr_render_job_ws_submit_info_init`;
  `winsys/powervr/pvr_drm_job_render.c:pvr_drm_winsys_render_submit`.
- **Verify**: `vk-tri TRI_DRAWS=N` at full size, raising N until the
  geometry job hangs; `apple_pm_trace` (a bring-up trace, now only in `tools/a10/kernel/bringup-driver-with-selftests.patch`) showed pages used per scene.
- **A9**: firmware-dependent, unknown. Check whether the A9 firmware's
  StartTA sequence has an out-of-memory branch before copying the stopgap.

---

## 4. Shared upstream code G9P must bypass, and why

These gates live in upstream files. They can't be inferred from the G9P
files alone, and missing one gives hangs or CPU cost, not compile errors.
Each is `PVR_HAS_FEATURE(dev_info, apple_g9p)` unless noted.

| # | Upstream place | G9P does instead | Why |
|---|---|---|---|
| 1 | `pvr_arch_framebuffer.c:pvr_arch_render_state_setup` (per-render SPM EOT/background state) | skips the loop body | No SPM on G9P; EOT and background come from `g9p_job_init`. Each skipped render saves a NIR+PCO shader compile and buffer allocations. |
| 2 | `pvr_arch_mrt.c:pvr_arch_mrt_load_ops_setup` | returns early | Loads and clears are G9P's background object; the load-op programs were a compile and upload per `vkCmdBeginRendering`. |
| 3 | `pvr_arch_cmd_buffer.c:pvr_sub_cmd_gfx_job_init` (`barrier_store` SPM scratch store; `barrier_load` with `enable_bg_tag`/`process_empty_tiles`) | `pvr_arch_g9p_job_init` | EOT/background/image state are Apple's; empty-tile policy is in `g9p_frag_stream` (3.4). |
| 4 | `pvr_perform_start_of_render_attachment_clear` | returns | Clears are background objects. |
| 5 | `CmdBeginRenderPass2`, `CmdNextSubpass2` (`pvr_cs_write_load_op`) | skipped | Same: Rogue load-op programs would be USC code G9P can't run. |
| 6 | `rogue/pvr_blit.c:pvr_rogue_CmdClearAttachments` | `g9p_clear_attachments` (two triangles per rect, clear shader, colour by DMA) | Rogue's clear programs hung the geometry job (Hyprland's `glClear`, `73cb8c5669a`). Depth/stencil clears do nothing yet. |
| 7 | `CmdDraw`, `CmdDrawIndexed` | `pvr_arch_g9p_cmd_draw` | Draws are G9P VDM/PPP words with G9P PDS programs. |
| 8 | `pvr_cmd_dispatch`; compute sub-command end (`pvr_arch_compute_generate_fence`) | `g9p_cmd_dispatch`; `g9p_end_pass` | Apple's CDM record format; every compute pass must end with iPadOS's four end-of-pass records or groups are lost and the GPU can wedge (COMPUTE.md). |
| 9 | `pvr_arch_pipeline.c`: graphics/compute pipeline compile and destroy | `g9p_*_pipeline_compile/destroy` | `pco` can't produce A10 code (1.9). |
| 10 | `pvr_arch_image.c:CreateImageView`, `pvr_arch_sampler.c:CreateSampler` | G9P texture/sampler words in the descriptor | Apple's older texture state layout (3.7). |
| 11 | `pvr_image.c:get_pbe_stride_align` | 16 pixels | Row pitch in 64-byte units. |
| 12 | `pvr_arch_queue.c:pvr_queue_init` | no transfer context | The firmware has no transfer engine; the kernel refuses the context. |
| 13 | `pvr_arch_queue.c:pvr_process_transfer_cmds` | `g9p_transfer_submit` (CPU) | No GPU transfer path; all memory is CPU-visible. Needs the VMA registry in `pvr_device.c:pvr_bind_memory`/`pvr_unbind_memory`. |
| 14 | `pvr_arch_job_render.c:pvr_arch_render_target_dataset_create` (local free list per dataset) | the device's shared list | 3.9. A list per dataset hung Hyprland's first render to a second target. |
| 15 | `pvr_render_job_ws_{geometry,fragment}_state_init` | `g9p_geom_stream`/`g9p_frag_stream` (gated on `job->g9p.enabled`) | Apple register block (3.1). |
| 16 | `pvr_render_job_ws_submit_info_init` (partial-render job) | empty PR stream | The kernel's Apple path has no partial renders. |
| 17 | `winsys/powervr/pvr_drm_job_render.c` (not feature-gated: keyed on an empty PR stream) | 1 or 2 jobs; fragment sync count goes to the last job | With the PR job skipped, the fragment job got the PR job's sync count and lost its signal: every second submit waited forever (`cd3abe91d03`). |
| 18 | `pvr_arch_device.c:create_device`/`destroy_device` | adds `g9p_device_init`, `g9p_gfx_device_init` | Device-level G9P programs (clear, load, EOT, 0x470, HALT, DMA, stream-out, context buffers), the compute end-of-pass programs and the free list. |

Details on rows 1 and 2, since they're the most recent and the least obvious:

- **What**: Zink renders with dynamic rendering, so every
  `vkCmdBeginRendering` runs `pvr_arch_render_state_setup` and
  `pvr_arch_mrt_load_ops_setup`. Upstream they build Rogue's SPM
  end-of-tile and background programs and the load-op programs: two shader
  compiles through NIR and PCO plus buffer allocations per render. G9P
  never runs any of them.
- **Evidence**: `perf` showed a third of Hyprland's CPU time in the Vulkan
  driver, mostly the NIR/PCO compiler (MESA.md "Live blur at 60 fps").
  Commit `b9721ab4b49`: about 2.5 ms CPU per Hyprland frame (ten renders).
  With live blur behind a moving window, frames went from 18.5 to 16.7 ms
  (617 of 618 under 20 ms), and Hyprland's CPU time per frame dropped by a
  quarter.
- **Verify**: `perf record` Hyprland on the device (Debian `linux-perf` in
  the chroot) and look for `pco_*`/`nir_*` under `vkCmdBeginRendering`.
- **Still per render, not measured (inference)**:
  `pvr_arch_render_state_setup` still fetches the SPM scratch buffer and
  creates the PPP state BO. If profiles show them, they're the next
  candidates.
- **A9**: same. These are Mesa-side lessons and apply to any Apple GPU on
  this driver.

Not gated, and likely to break if used (inference: no G9P path exists):

- `CmdDrawIndirect`, `CmdDrawIndexedIndirect`, `CmdDrawIndirectByteCountEXT`
  fall through to the Rogue path.
- `CmdDispatchIndirect` and base groups aren't supported (comment in
  `pvr_cmd_dispatch`).
- Device creation still runs upstream's Rogue device-level setup (view
  index programs, query programs, static clear state). These are prebuilt
  and never executed on G9P, so harmless so far (inference).

---

## 5. Debug knobs

All are read by the Vulkan driver (set them in the environment of the app,
e.g. Hyprland). Output goes to stderr with a `g9p:` prefix.

| Variable | What it does | When to use it |
|---|---|---|
| `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1` | Upstream gate in `pvr_physical_device.c`: without it, a non-conformant device (the A10) fails with `VK_ERROR_INCOMPATIBLE_DRIVER`. | Always, for any app. |
| `G9P_TRACE=1` | Per render as submitted, no waiting: number, size, loaded/cleared, draw count, submit time in ms, render area, tiles covered by draws' region clips, load op, first 12 pipeline ids (`pvr_arch_queue.c:pvr_process_graphics_cmd_for_view`). | GPU hangs (the last lines name the render; the kernel's timeout report names the job); frame intervals; checking load ops and covered area. |
| `G9P_SYNC=1` | Waits for every render's geometry then fragment job (0.5 s each) and every compute job (3 s). Reports a timeout with the job type and pipeline ids, and whether the render's own waits were signalled (2 s). Also logs each render-target dataset created. | Finding the render that hangs. Note: it serializes everything and changes timing; it hid the blur-cache race (6.4). |
| `G9P_TIME=1` | With `G9P_SYNC=1` only: per render, geometry and fragment job time in µs and pipeline ids. | Where a frame's GPU time goes (MESA.md "Where a frame goes"). |
| `G9P_PROBE=1` | With `G9P_SYNC=1`, if `G9P_TIME` is unset: eight pixels down the target's diagonal after each render. | Quick correctness check without files. |
| `G9P_GRAB=N` | With `G9P_SYNC=1`, if `G9P_TIME` and `G9P_PROBE` are unset: writes the first N renders' targets to `/tmp/g9p-grab-K.raw` (twiddled: Morton, y bit first, over the power-of-two size; linear: pitch x height). | Seeing intermediate renders (e.g. each blur pass). |
| `G9P_GRAB_LOADED=1` | With `G9P_GRAB`: only renders that load their target. | Damage-only redraws. |
| `G9P_GRAB_SKIP=K` | With `G9P_GRAB`: skip the first K twiddled targets. | Grabbing later frames. |
| `G9P_ALL_TILES=1` | Forces ISP_CTL bit 17 on for every render (`g9p_frag_stream`). | A/B for tile-skipping bugs (3.4). |
| `G9P_NO_NATIVE_BLEND=1` | Uses `nir_lower_blend` in f32 instead of Apple's f16 source-over sequence. | A/B for blending bugs (3.8). |
| `G9P_DEBUG=1` | Compiler: NIR before code generation, "N registers, M bytes" and the code in hex per shader, out-of-register dumps (busy/pinned/temp masks, live values), the NIR instruction it can't compile. Driver: `g9p: pipeline N` before each pipeline's shaders (matches the ids in TRACE/SYNC/TIME). | Compiler failures, register pressure, mapping pipeline ids to shaders. |
| `G9P_DUMP=1` | Everything built: USC code and PDS programs per pipeline, PPP blocks, draw DMA, buffer address tables and the first 16 dwords of each buffer, texture descriptors, fragment common-store DMA, image state, both job streams. At queue submit, it also waits up to 0.5 s per pending sync and reports those still pending. | Comparing against `pvr-tri` or an iOS capture. Slow. |
| `G9P_DUMP_FULL=1` | With `G9P_DUMP=1`: buffer dumps 128 dwords instead of 16. | Replaying a draw's uniforms in `vk-tri TRI_UBO_FILE`. |
| `G9P_PMDUMP=N` | Allocates VHEAP/RTC and macrotile-array buffers CPU-mapped. Every Nth render, prints their first 16 words. | Parameter-manager investigations (it showed zeros throughout; the hang turned out to be firmware/kernel). |
| `G9P_REGS=N` | Overrides the register budget (default 30, max 63). | Testing spilling to homes at low pressure. |

How the `G9P_SYNC` variants combine: TIME, PROBE and GRAB are an
`else if` chain after the hang check, so only the first one set takes
effect.

Kernel-side companions (not Mesa): `modprobe powervr dyndbg=+p` for firmware
mailbox messages, `apple_pm_trace` (`tools/a10/kernel/bringup-driver-with-selftests.patch`), and the kernel's `hang: fragment job N`
timeout report. Recovery trap: a hung job can leave processes in state D. If
`rmmod` fails, reboot, and treat later results as invalid (MESA.md).

- **A9**: same knobs. They live in shared and G9P files and key on
  `has_apple_g9p`/`job->g9p.enabled`.

---

## 6. Zink and Hyprland specifics

### 6.1 What Zink needs from the driver

- **What**:
  - Dynamic rendering: every render is a `vkCmdBeginRendering`, so
    per-render driver work is per-frame CPU cost (section 4, rows 1-2).
  - Extended dynamic state: vertex strides arrive at bind time, so the
    vertex shader reads each binding's stride from the common store
    (`G9P_VERTEX_STRIDES`). Before that, every Zink draw collapsed to a
    point.
  - BGRA through swizzled RGBA views (3.7).
  - CPU transfers.
  - Push descriptors and buffer addresses read from descriptors.
  - Outputs beyond colour attachment 0 dropped.
  - The winsys partial-render sync fix (section 4, row 17).
- **Evidence**: `cd3abe91d03`, `73cb8c5669a`, `2f09119a9bc`.
- **Display path**: GBM on card0 (simpledrm) without an override: kmsro
  finds the PowerVR render node and falls back to Zink with renderonly
  (97.7 fps clear + triangle). Forcing `MESA_LOADER_DRIVER_OVERRIDE=zink` on
  card0 breaks it (MESA.md "Zink, GBM and the display").
- **A9**: same (Mesa-side).

### 6.2 Frame time is CPU time plus GPU time

- **What**: Zink submits a frame only after Hyprland has recorded all of it.
  The CPU time per frame comes *before* the GPU's, not beside it. A frame is
  late when CPU recording plus the GPU chain (about ten renders back to
  back: composite, blur chain, copy to scanout, about 10.6 ms) exceeds the
  interval. CPU hand-offs between jobs measured 15-30 µs.
- **Evidence**: MESA.md "Live blur at 60 fps" (kernel timeline, bring-up
  only).
- **Verify**: `G9P_TRACE` timestamps for submit intervals; `perf` for the
  CPU side.
- Other speed factors are kernel-side: GPU performance state (33 to 19 ms
  per live-blur frame) and job-completion polling (an empty render 4.3 to
  0.65 ms).
- **A9**: the CPU-before-GPU structure is the same. Absolute budgets differ.

### 6.3 Blur needs a client request and window opacity below 1

- **What**: Hyprland 0.57 blurred nothing behind foot until foot asked for
  it with `colors-dark.blur=yes` (ext-background-effect), as Omarchy's foot
  theme does. Even then it treats foot's see-through buffer as opaque, so
  the focused window (opacity 1) gets no blur; the Jade Horse config uses
  0.97. The GPU side was fine all along: `G9P_GRAB` of the chain (prepare,
  three passes down, three up, finish) showed blurred images.
- **Evidence**: MESA.md "The effects demo". Configs `mesa/hyprland-jade.lua`,
  `mesa/foot-jade.ini`.
- **A9**: same (application behaviour).

### 6.4 Blur cache race with wallpaper loading

- **What**: with `new_optimizations`, Hyprland computes its cached blurred
  wallpaper once the first translucent windows appear, and keeps it. If
  windows come before the asynchronous loader has the wallpaper (the 4.6 MB
  Jade Horse PNG), the cache holds the empty screen (black) or an unblurred
  image. Faster GPU job checks and `G9P_SYNC=1` both shift the race.
  Windows opened 8 s after start, or `hyprctl reload` after startup,
  blur correctly every time; `hypr-demo.sh` reloads.
- **Evidence**: MESA.md "The effects demo".
- **Verify**: before suspecting the driver for a black or unblurred
  background, reload and compare.
- **A9**: same.

---

## Open questions

1. Partial renders: how iPadOS branches on PM_OUT_OF_MEMORY (the kext's
   `encodePartialRenderSetup`). Until then, a heavy scene hangs the GPU until
   reboot.
2. Fragment memory loads (`2012`/`3812` forms): what makes ours hang. They
   are needed for buffers past 512 bytes and dynamic offsets in fragment
   shaders.
3. More than one texture per shader: why only state at dword 0 samples
   correctly.
4. Sampler fields: mirrored and border wrap modes, the remaining format
   codes, and non-trivial swizzles in the image state. (Minification and
   repeat are settled: section 3.7, Mesa `3ca781076f4`.)
5. Depth/stencil (kmscube hangs), MSAA, multiple colour attachments, blend
   constants, indirect draws.
6. Register 0x470's program (`015e a000`) and the EOT image state's second
   (zero) address: meanings open.
7. Compiler speed: border and shadow shaders dominate composite time (2.6).
   Apple uses f16 operand forms and predication where we use f32 and the
   mask stack. Two register-pressure ideas were tried on an unfinished
   branch (Mesa `wip/g9p-border-pressure`, never published, deleted
   2026-11-02; the border shader was made to fit with registers above r31
   instead) and are not on `main`:
   - **If-ladders to selects:** Hyprland's border shader reads two local
     `vec4[10]` arrays with dynamic indices, which NIR turns into if-ladders
     that keep phi webs alive across the ladder. `nir_opt_peephole_select`
     with `.limit = 0` turns ladders whose legs only choose a value into
     selects.
   - **Copies at the use:** cheap loads (uniforms, varyings, the fragment
     position) are copied right before each use, and for a phi source at
     the end of its predecessor block, so no such value stays live across
     branches. `main`'s `rematerialize_loads()` does a simpler version.
   Both cut register pressure. Whether they make the shaders faster, not
   only smaller, was never measured: try them with `hypr-bench.sh time`.
8. Remaining per-render CPU work in `pvr_arch_render_state_setup` (SPM
   scratch buffer, PPP state BO): not profiled.
9. (Fixed) A grab during a slow window resize showed doubled text: the
   sampler packing had linear minification and V repeat swapped (MESA.md
   "Resize glitch", Mesa `3ca781076f4`).
10. A9: is the shader ISA Apple's (and which `metal-tt` target), does its
    firmware's geometry sequence handle out-of-memory, and does it blend in
    the shader? Answer these first. They decide how much of `g9p/` and
    section 3 carries over. Section 4 and the debug knobs carry over either
    way.
