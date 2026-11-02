# Mesa for the A10 GPU (G9P): plan and map

Userspace plan for the A10 GPU (iPad 6, T8010, PowerVR-derived, Apple
shader ISA "applegpu_g9p"). Status 2026-10-31: **Vulkan compute and a first
graphics frame run on the A10 through the fork** (branch `g9p`):
`mesa/vk-compute-test` (12 shaders), `mesa/vk-fx`, and `mesa/vk-tri` (a
cleared 64x64 BGRA8 image with a vertex-coloured triangle, dynamic
rendering; RENDER.md "The first Vulkan frame").

## Decisions

- **Route: Vulkan + Zink** (user, 2026-10-31). Extend Mesa's Imagination
  Vulkan driver (`src/imagination/vulkan`, "pvr"), which already speaks the
  upstream powervr UAPI our kernel driver implements, with a G9P shader
  backend in place of its `pco` compiler. OpenGL (ES) for the desktop then
  comes from Zink.
- **Fork, not upstream:** `src/imagination/README.md` says the PowerVR
  maintainers decline LLM-generated contributions, and Mesa's AGENTS.md asks
  agents not to change `src/imagination`. Decided with that in mind (user,
  2026-10-31): the work stays in our fork and is made compliantly. Every
  commit carries the trailer `Generated-by: LLM`; nothing is sent to Mesa's
  GitLab (no merge requests, no comments). Upstreaming only if the policy
  changes or a human author takes ownership.
- **G9P as a runtime feature, not a second arch (for now):** the A10 is
  Rogue-like at the CDM/PDS/firmware level, so the fork gates the differing
  points on a device feature `has_apple_g9p` instead of compiling every
  `pvr_arch_*` file a second time. Can become `PVR_DEVICE_ARCH_G9P` later if
  the differences grow.
- **Home:** a standalone Mesa clone, local for now:
  `~/projects/OrchardLinux/mesa-g9p` (upstream main at `801952de2f1`,
  blob-filtered clone). It moves to a hosted fork once a distro package
  needs a URL.
- **Delivery:** dev loop = build in a container, push the driver into a
  chroot on the iPad (below). Release = a distro package (Arch-style
  PKGBUILD in the distro) building the fork at a pinned commit.

## Build and test environment

- `mesa/Containerfile` → `localhost/orchard-mesa-g9p:trixie` (Debian trixie
  arm64, native on Apple Silicon): Mesa's build dependencies. The
  Imagination driver needs LLVM 19 + libclc + SPIRV-LLVM-Translator even
  without pco, for its OpenCL C internal shaders (`mesa_clc`).
- `mesa/Containerfile.runtime` → `localhost/orchard-mesa-g9p-runtime:trixie`
  (153 MB): the device userland (same Debian, Vulkan loader, vulkaninfo).
  Plan: `podman export` it, unpack into the iPad's `/run` (950 MB tmpfs,
  1.9 GB RAM), bind-mount `/dev`, `/proc`, `/sys` and chroot; install the
  built `libvulkan_powervr_mesa.so` and its ICD JSON inside.
- Baseline build (unmodified upstream, works):

  ```
  podman run --rm -v $MESA:/mesa -w /mesa localhost/orchard-mesa-g9p:trixie sh -c \
    'meson setup build-arm64 -Dvulkan-drivers=imagination -Dgallium-drivers= \
       -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
       -Dbuildtype=debugoptimized -Dprefix=/usr && ninja -C build-arm64'
  ```

- Device loop (first version, Debian trixie, Vulkan only; since replaced by
  `mesa/deploy-zink.sh`, see "Zink" below): created the chroot once per boot
  (runtime image incl. strace and gdb), installed the driver and ICD, and ran
  a command in it, e.g. `'PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 vulkaninfo --summary'`.
- No-hardware testing: `src/imagination/drm-shim/pvr_noop.c`
  (`-Dtools=drm-shim`, `PVR_SHIM_DEVICE_BVNC=b.v.n.c`) fakes the powervr
  device for instance/device/pipeline creation and command recording, with
  `PVR_DEBUG=dump_control_stream`. It needs a Linux host (the container).

## Map of the pvr driver (from a read of upstream main, file:line)

Paths under `src/imagination/`.

- **Device identification.** The winsys reads the packed BVNC from
  `DRM_PVR_DEV_QUERY_GPU_INFO_GET` (`vulkan/winsys/powervr/pvr_drm.c:292-305`).
  `pvr_device_info_init()` (`common/pvr_device_info.c:79`) switches over
  known BVNCs, so an unknown one fails "Unsupported BVNC" (`pvr_drm.c:318-327`).
  Quirks/enhancements come from the kernel queries; an unsupported
  "musthave" quirk fails (`pvr_drm.c:124-273`). A second gate,
  `pvr_device_is_conformant()` (`vulkan/pvr_physical_device.c:1140-1155`),
  needs `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1` for other devices. Device
  tables: `common/device_info/*.h` (template: `axe-1-16m.h`); features
  tested with `PVR_HAS_FEATURE` / `PVR_GET_FEATURE_VALUE`
  (`common/pvr_device_info.h:148-387`). Our kernel decides which BVNC it
  reports.
- **Per-architecture split.** `vulkan/pvr_arch_*.c` and `vulkan/rogue/*.c`
  are compiled once per architecture with `-DPVR_BUILD_ARCH_<ARCH>` into a
  static library (`vulkan/meson.build:85-178`, today only `rogue`).
  `PVR_PER_ARCH(name)` names functions per arch, `PVR_ARCH_DISPATCH*`
  switches on `dev_info.ident.arch` (`vulkan/pvr_macros.h:58-84`).
  `csbgen/volcanic/` is an existing second XML namespace to copy.
  Rogue assumptions to gate: `winsys/pvr_winsys.h:194-230` (static state),
  `pvr_drm_job_compute.c:59-60`, `pvr_physical_device.c:1460-1463`,
  `pvr_arch_pipeline.c:3079`, `pvr_csb.h:52-63` and `:287-305` (ROGUE_
  prefix paste), `pvr_arch_job_context.c:855, 1109` (`#error "Missing arch"`).
- **Compiler interface (pco).** Context: `pvr_physical_device.c:1307-1317`.
  Compute pipeline: `pvr_compute_pipeline_compile`
  (`vulkan/pvr_arch_pipeline.c:984-1135`): SPIR-V → NIR with pco options,
  pco preprocess/lower/postprocess, `pvr_setup_descriptors` (driver lays out
  the shader's shared registers, `:2506-2672`), `pco_trans_nir` →
  `pco_encode_ir`, upload with `pvr_gpu_upload_usc`, then the PDS programs.
  The driver reads `pco_data` (`pco/pco_data.h`): temps, coeffs/shareds,
  sys_vals (which PDS registers get local ID / workgroup ID / counts,
  `pvr_arch_pipeline.c:735-750`), descriptor ranges, cs workgroup size and
  shared memory. Internal shaders through pco: `vulkan/pvr_usc.c`
  (EOT, transfer, loadop, clear, SPM, zero-init of workgroup memory) and
  build-time precompiled `_common` USC binaries from `pco/usclib/*.cl`
  via `pco_clc` (NOP, IDFWDF, compute context store/load SR, queries,
  passthrough VS).
- **PDS.** Compute uses the hand-coded generator `vulkan/pds/pvr_pds.c`
  (`pvr_pds_compute_shader` `:1756`, `pvr_pds_kick_usc` `:3743`,
  `pvr_pds_generate_doutw` `:3632`, `pvr_pds_generate_doutc` `:3564`,
  shared loading `:4019`, fence-terminate `:3916`) and
  `pvr_pipeline_pds.c` (descriptor upload `:1526`). Instruction words come
  from `pvr_rogue_pds_encode.h:514-536` and field macros in
  `pvr_rogue_pds_defs.h:1093+`; data words from `pvr_pds_setup_doutu`
  (`pvr_pds.c:485-525`) and `pvr_pds_encode_dma_burst` (`:446-470`).
  G9P's DOUT layout differs (COMPUTE.md "Apple PDS DOUT encoding"; our
  encoder `tools/g9p-cdm.h`), so these encoders need a G9P variant.
- **Compute dispatch.** `vkCmdDispatchBase` → `pvr_cmd_dispatch`
  (`pvr_arch_cmd_buffer.c:6652-6713`) → descriptor PDS, shared loading
  kernel (`:6285`), kernel update (`:6499`) →
  `pvr_compute_generate_control_stream` (`:2142-2229`, CDMCTRL_KERNEL0..8
  from `csbgen/rogue/cdm.xml`). Sub-command end (`:2582-2595`): fence
  kernel, then `pvr_arch_csb_emit_terminate` (`pvr_arch_csb.c:331-352`).
  **G9P's end-of-pass records (`g9p_cdm_end_pass()`) go between the fence
  (`:2586`) and the terminate (`:2588`)**, or into the terminate under the
  G9P arch. Firmware command stream: `pvr_arch_job_compute.c:43-180`;
  submit: `winsys/powervr/pvr_drm_job_compute.c:164-232`
  (`DRM_IOCTL_PVR_SUBMIT_JOBS` with syncobj sync ops).
- **Winsys.** `winsys/powervr` uses only upstream UAPI (dev queries, heaps,
  VM/BO/map, contexts, free lists, HWRT datasets, submit). It writes Rogue
  static programs into the kernel's static data areas at creation
  (`winsys/pvr_winsys_helper.c:283-351`): harmless if never run, but our
  kernel must report those areas.

## Differences from Rogue that the port must handle

From the A10 work in this directory:

- Shader ISA: Apple's own (ISA.md), so a new NIR → G9P backend.
- PDS: DOUT field layout differs (bits 0-2 type, 3-7 64-bit source, 8-9
  space, 10-15 control dword, 26 END, 27 CC).
- CDM records: 8 words; K0 = fence / any-cluster / data size (16-byte
  blocks − 1) / block type; K1 low bits are flags; words 3-5 groups − 1;
  word 6 = (threads mod 32) << 27 | threadgroup allocation; word 7 =
  (threads − 1) << 20 (`tools/g9p-cdm.h`).
- Workgroup IDs: written by our PDS program into threadgroup words 0-2 in
  the coefficient task (COMPUTE.md "Group IDs work"), not Rogue's scheme.
- Every compute pass must end with iPadOS's four end-of-pass records
  (`g9p_cdm_end_pass()`), or groups are lost and the GPU can wedge.
- Buffer binding: a DMA (DOUTD) task loads the buffer address and thread
  count into the USC common store (16 dwords by default).
- The kernel side (our driver) must report a BVNC, quirks and heaps the
  winsys accepts. GPU data paths are 38-bit: heaps below 2^38.

## Milestones

Done so far (fork commit on `g9p`): device entry
`common/device_info/apple-a10.h` (BVNC 13.10.6.2; A10-established values
marked, others GX6650 placeholders), feature `has_apple_g9p`, no transfer
context on it (the kernel returns EOPNOTSUPP for that context type).

Compute path (fork commit "G9P compute backend and dispatch"):
- `src/imagination/g9p/`: `g9p_compile.c` (NIR → G9P: one basic block,
  32-bit integer ALU, local index, workgroup ID x/y, storage-buffer
  loads/stores, registers r0-r7), `g9p_isa.h` (USC encoders mirroring
  `tools/isa/g9p.py`), `g9p_cdm.h` (copy of `tools/g9p-cdm.h`).
- `vulkan/pvr_arch_g9p.c`: pipeline compile, dispatch (a DMA task loads
  each storage buffer's address from the bound descriptor set into
  common-store dwords 2k-2k+1 and the thread count after them; the kernel
  task writes the workgroup ID into threadgroup words 0-1), end of pass
  (Apple's four records before the terminate), device programs.
- Hooks gated on `has_apple_g9p` in pipeline create/destroy, dispatch,
  sub-command end and device create/destroy.
- Backend v2 (fork commit "control flow, floats, push constants"):
  structured control flow on the mask stack (if/else, loops, breaks),
  floats, compares, conversions, shifts, min/max, selects, push constants,
  up to r29. `mesa/vk-compute-test NAME` runs 12 shaders (all pass,
  bit-exact); `mesa/vk-fx` is a GLSL Julia effect at 60-90 fps.
- Hardware rules the backend follows (ISA.md): jump offset bit 8 in bit 0;
  no select/move pairs (they break with masked lanes) - predicated copies
  instead; branch conditions compare directly; skip to the loop exit
  after each break; K0 register field from the register count.
- Transcendentals (floor, rcp, rsqrt, log2, exp2, sin, cos) and with
  NIR lowering division, pow, sqrt, fract, mix, step, sign, saturate.
- `mesa/vk-play SHADER.spv` plays any compute shader on the framebuffer
  (push constants time/width/height); `mesa/frag2comp.py` wraps a
  WebGL-style fragment shader (uTime, vUv, gl_FragCoord, gl_FragColor) for
  it. Parked (2026-10-31): a large noise shader (about 14 inlined simplex
  noise calls) needs 60 registers, the hardware gives at most 32 per
  thread, so it needs register spilling. Moving instructions to their uses
  (`nir_opt_move`) cut its pressure; rematerializing push-constant/ID
  chains did not help. Spilling is not on the Hyprland critical path.
- Not yet: register spilling, UBOs, dynamic buffers, base groups and indirect dispatch,
  workgroup ID z, 16-bit half registers, inline constants; performance
  is about 2x behind Apple's compiler on the Julia effect.

1. **Compute-only Vulkan** (vkCreateComputePipelines, vkCmdDispatch,
   storage-buffer writes checked through host-visible memory):
   - device-info header `common/device_info/g9p.h`, BVNC agreed with the
     kernel, `PVR_DEVICE_ARCH_G9P`;
   - arch plumbing: compile the `pvr_arch_*` files a second time with
     `-DPVR_BUILD_ARCH_G9P`, `#if` at the differing points, `csbgen/g9p/`;
   - a compiler interface in place of the ~15 pco call sites, with a G9P
     backend covering what ISA.md has decoded (moves, integer/float ALU,
     compares, branches, loops, loads/stores, IDs);
   - G9P PDS encoders for the compute program, descriptor upload, fence;
   - guard off graphics/transfer/SPM/clear/query setup in device and queue
     creation (they compile shaders through pco);
   - end-of-pass records before the terminate.
2. Transfer (copy/fill) and queries.
3. Graphics: render passes, the Apple render extension in our kernel
   UAPI, fragment I/O and textures in the ISA (still to decode).
4. Zink on top for GL; then the desktop.

## Zink, GBM and the display (2026-10-31)

**GLES 3.1 through Zink on the A10 reaches the iPad's screen.** Userland:
Debian unstable (it packages Hyprland), the fork built with Zink, EGL
(glvnd), GBM and the Wayland platform (`Containerfile.sid`, build dir
`build-zink`), installed over the runtime chroot `/run/sid`
(`Containerfile.runtime-sid`, `deploy-zink.sh`; `push-vk-zink.sh` pushes
only the Vulkan driver).

- `eglinfo -p surfaceless`: OpenGL ES 3.1, OpenGL 3.2 core, renderer
  "zink Vulkan 1.2 (PowerVR Apple A10)".
- **Display path** (`mesa/gbm-kms-test`): the display is simpledrm
  (card0, 1536x2048, stride 6144), the GPU a render-only node
  (renderD128). Two ways work:
  - GBM on the render node with `MESA_LOADER_DRIVER_OVERRIDE=zink`, each
    frame's dma-buf imported into simpledrm (`drmPrimeFDToHandle`,
    `drmModeAddFB2`): 89 fps for a full-screen clear and a triangle.
  - **GBM on card0 without an override**: Mesa's pipe loader falls back
    to kmsro for the unknown KMS driver, kmsro finds the PowerVR render
    node and falls back to Zink with renderonly (scanout buffers are
    simpledrm dumb buffers imported into the GPU): 97.7 fps. This is the
    path compositors (Aquamarine) take; forcing the driver to Zink breaks
    it (Zink needs a render node on the fd it is given).
- What Zink needed from the G9P path: transfers (none on the GPU yet:
  `pvr_arch_g9p_transfer.c` runs copies/blits/fills on the CPU, through a
  registry of bound memory), uniform buffers, push descriptors and buffer
  addresses read from the descriptors, dropping outputs beyond colour
  attachment 0, and a DRM winsys fix (the fragment job lost its signal
  when the partial-render job is skipped, so the second submit waited
  forever).
- `kmscube` (depth-tested cube) hangs the GPU: depth is not implemented
  in the G9P path yet.

## Hyprland renders (2026-10-31, Mesa fork `5208bab21cf`, `73cb8c5669a`)

Hyprland 0.57 runs on the A10 without GPU job timeouts and draws its frame
(overlay text, notifications, the cursor) into its offscreen buffer. What
it took, each found with a reproduction outside Hyprland:

- **Fragment shaders computed nothing** (`5208bab21cf`, ISA.md "Fragment
  register bank"): fragment code needs its own register-bank encoding,
  iterates count components modulo 4, and conditional discard takes
  Apple's compare form. `mesa/fsops.py` tests 15 groups of operations.
- **The parameter buffer** (geometry jobs hung after two draws with their
  own state, or 32 instances): the Apple firmware takes a render's *local*
  free list as its whole parameter buffer, never grows it and reloads its
  registers only when the command's free-list index changes, which the
  kernel keeps at 0. Every render-target dataset now shares one 8 MiB
  device list (`G9P_FREE_LIST_SIZE`, `pvr_arch_render_target_dataset_create()`).
  A kernel that indexes free lists properly would allow one per dataset.
- **`vkCmdClearAttachments`** (Hyprland's `glClear`) recorded Rogue's clear
  programs and hung the geometry job; it is now a draw of the rectangles
  with the background clear shader (`g9p_clear_attachments()`).
- **Every Zink draw collapsed to a point**: with extended dynamic state,
  Zink sets vertex strides at bind time and the pipeline's are 0; the
  vertex shader now reads each binding's stride from the common store
  (`G9P_VERTEX_STRIDES`).
- **Fragment uniform buffers and push constants**: memory loads in
  fragment code do not work yet (they hang or read zeros), so a buffer's
  first dwords are DMA'd into the fragment common store per draw and read
  as uniform operands, as Apple does (ISA.md "Fragment uniforms").

- **Load ops** (`47c5ed2f74b`): the background object samples the target
  at the pixel position (iPadOS's `load` capture), so damage-only frames
  keep the rest.
- **Scissors** (`47c5ed2f74b`): per-draw scissor table entries; Hyprland
  copies its offscreen frame to the screen scissored to the damage.

**Hyprland shows on the iPad (2026-10-31 ~12:00)**: with
`mesa/hyprland-test.lua` (Hyprland 0.57 reads `~/.config/hypr/hyprland.lua`;
no blur, shadows or animations, background 0x336699) the screen
(`mesa/kms-grab`) is the background with Hyprland's cursor, no GPU job
timeouts. Debian's package ships no wallpapers.

**A terminal window (2026-10-31 ~11:50)**: `foot`, started by the
config's `hyprland.start` hook, fills the screen as a tiled window with its
text and shell prompt (it needed `/dev/pts` in the chroot: `deploy-zink.sh`
binds it now).

Still open, in order:

1. ~~**Blending**~~: done, see "Blending" below.
2. ~~Hyprland's border shader~~: drawn, see "Window borders" below.
3. Performance and the remaining Vulkan features (depth, more than one
   texture per shader, fragment memory loads).

**Debugging aids** (environment of the Vulkan driver): `G9P_SYNC=1` waits
for every render and compute job and reports a hang with the pipeline ids
of its draws (printed before their shaders with `G9P_DEBUG=1`) and whether
its waits were signalled; `G9P_GRAB=N` writes the first N renders' targets
to `/tmp/g9p-grab-K.raw` (decode twiddled ones with a Morton order, y bit
first, over the power-of-two size); `G9P_DUMP=1` prints stream words,
buffer address tables, texture descriptors and the fragment common-store
DMA. `mesa/kms-grab` writes what the display scans out as a PPM (root,
while the compositor runs).

**Reproductions** in `mesa/vk-tri`: `TRI_DRAWS`, `TRI_INSTANCES`
(parameter buffer), `TRI_CLEARATT`, `TRI_PRE`/`TRI_PRE_LINEAR`/
`TRI_PRESAME`/`TRI_DEV2` (other targets and devices first), `TRI_PAD_MB`
(high GPU addresses), `TRI_RGBA`, `TRI_STRIP`, `TRI_FLIPY`,
`TRI_TEX_SIZE` (large and NPOT textures), `TRI_VS_SPV`, `TRI_PUSH`; in
`mesa/gbm-kms-test`: `GBM_DRAWS`, `GBM_FS_UNIFORM`, `GBM_KEEP`.

## Blending (2026-10-31, Mesa fork `0ca35c1de72`)

Blending is fragment shader code, as on iPadOS (ISA.md "Tile read and
blending"). For a pipeline whose first colour attachment blends, has a logic
op or a partial write mask, `blend_options()` (pvr_arch_g9p_gfx.c) fills
`nir_lower_blend_options` and `g9p_compile_fragment()` runs `nir_lower_blend`
after IO lowering; the pipeline marks its draws translucent (pass type 1)
when the shader reads the tile (`uses_fbfetch`).

`nir_lower_blend` reads the attachment with `load_output`. `lower_fb_fetch`
(g9p_compile.c) turns each f32 component into integer code on a raw 32-bit
word of the tile, `h ? ((h & 0x7fff) << 13) + 0x38000000 : 0` per half
(exact for unorm attachments), and `emit_fb_fetch()` gives that word: the
tile read into a free even register pair. Apple's own half-to-f32
conversion only reached r0-r2 in tests.

Tests: `vk-tri TRI_BLEND=1 TRI_VCOL=0.25,0.5,0.75,0.5 TRI_WANT=0xff4080df`
(premultiplied source-over over the clear colour, exact) and
`TRI_BLEND=dst TRI_WANT=0xff000040` (the tile kept). With blending, Hyprland
draws its cursor without the black square and shows its notifications.

Open:

- Settled: the first Hyprland run after a series of deliberately broken
  test shaders had 9 GPU job timeouts. A soak afterwards had none: 15
  Hyprland runs of 25 s, vk-tri blending with 200-1000 draws and with 32
  instances. Most likely state left by the broken shaders.
- The soak found a control stream bug: about 150 draws in one render
  asserted in `pvr_csb_buffer_extend()` (the draw set no relocation mark).
  Fixed in `06f246344a6`; `vk-tri TRI_DRAWS=1000` passes.
- Blend constants (`load_blend_const_color_*`) and attachments other than
  the first are not handled; sRGB and non-unorm formats are untested.
- Blending in f32 integer-unpacked form costs about 12 instructions per
  component; Apple's f16 operand forms would be cheaper.

## Scale 2, the intermittent hang and the border shader (2026-10-31)

`hyprland-test.lua` runs Hyprland at scale 2 (the 1536x2048 panel is a 2x
display, as on iPadOS). At scale 2 the GPU job timeouts came back:

- **Cause found in part: overlapping renders.** All renders share one free
  list. Mesa `8433037fe15` makes each
  render's geometry job wait for the previous render's fragment job: from
  timeouts in most 20 s runs to about one run in three (`2 0 0 0 0 2`). A
  CPU-side wait instead was no better (1 in 8). With `G9P_SYNC=1` (every
  job waited for) none: another overlap or state problem remains.
- **Recovery trap**: a hung job can leave processes in state D inside the
  driver; `rmmod` then fails and the old GPU instance stays. `hypr-once.sh`
  and `gpu-reload.sh` used to print "GPU module reloaded" anyway; they now
  say "NOT reloaded ... reboot the device". Results after such a wedge are
  invalid; a hang can also affect later runs even after a reload.
- `G9P_SYNC` waited 3 s, longer than the kernel's job timeout (which
  signals the hung job's fence): it never reported hangs; now 0.5 s.

Border shader (window borders): two `vec4[10]` gradient arrays filled from
40 uniform loads and read through if-ladders. Work on the fork's branch
`wip/g9p-border-pressure` (rematerializing uniform loads into phi
predecessors and per use, peephole selects, nested discards through a
flag) gets it from instruction 227 to about 580 before registers run out,
but even 32 registers are not enough. (Since solved with registers above
r31 instead of memory spilling: "Window borders" below.)


### The hang, narrowed (2026-11-01)

The kernel's timeout report (`hang: fragment job N; stamps ...`) shows every
hang the same way: a render whose geometry job finished and whose fragment
job the firmware never finishes; the firmware then runs nothing more and
waiters sleep in the driver (state D: reboot).

- **Found and fixed** (orchard `f35abc2`): file close unmapped the client's
  VM while the firmware still ran its last fragment job.
  `vk-tri TRI_EXIT_NOW=1` (exit right after the submit) hung on the first
  run; 40 of 40 clean with the fix.
- **Still open**: stopping Hyprland (`hypr-once.sh` sends SIGTERM, then
  kills Hyprland and seatd) still hangs its last fragment job, without the
  kernel's file-close wait failing. Candidates: the display device side
  (Hyprland's frames are shared with card0, which seatd holds; seatd also
  ends up in state D) or Hyprland's own teardown order.
- Hangs during a session (as opposed to at its end) were not seen in the
  last runs: the timeouts counted per run happen when Hyprland stops.

### The hang is a parameter-memory leak (2026-11-01)

With `G9P_TRACE` (Mesa `7572f420d11`) and `mesa/hypr-session.sh`:

- Not tied to stopping clients, idle gaps (vk-tri with 1-10 s pauses) or a
  fixed count (gbm-kms-test renders 3000 small frames fine).
- It depends on how much tiling (parameter) memory the renders use, and it
  accumulates. With the shared free list at 8 MiB, a busy session (a foot
  window printing without pause, about 33 full-screen draws per frame)
  hangs after 157 renders; at 32 MiB (temporary size switch) after 3473
  renders (190 s). Idle sessions hang after about 2000 renders.
- So memory the parameter manager takes per render is not all given back.
  The kernel rewrites the free-list descriptor as a full stack and clears
  the PM state block (HEAP_TA_PM_STATE) for every geometry job, so the
  leak is elsewhere: candidates are the per-render-target PM structures
  (macrotile list, VHEAP table, region headers in the HWRT dataset), which
  are not reset per scene, or pages the fragment job never deallocates.
- Next: dump the free list stack and the HWRT PM structures between scenes
  (pvr_apple_ta_dump() exists) and compare with iPadOS's second frame of a
  capture, which shows what the kext resets per scene.

Scenes are serialized by the kernel (each geometry job waits for the
previous fragment job), so the Mesa-side render ordering of `8433037fe15`
is redundant and can go once this is fixed.

`apple_pm_trace=10` (orchard `08d7f27`) over a busy session that hung after
1073 renders (2026-11-01): the free-list descriptor stays the same from
scene to scene (base 0x4c000, 0x2000 bytes = 2048 pages of 4 KiB, top
0x7ff: the firmware writes no usage back), the PM state block does not
change, and the PM slot only switches between about 12 render targets
(macrotile list, macrotile array, VHEAP table) without drift. The leaking
state is therefore in GPU memory the firmware uses directly: next, dump
the first words of the current render target's macrotile list, VHEAP
table and region headers per scene, and compare one target's values
across its scenes.

Free-list stack check (orchard `9632209`, `apple_pm_trace=10`, busy session
that hung after 369 renders): the page stack stays intact. About 167
entries change order (the pages a scene took and gave back), none is
foreign and none repeats; a scene uses about 167 of the 2048 pages. So the
fragment jobs do give pages back, and the free list does not run out. The
larger free list helped because the macrotile list (the PM's page tables
for its virtual heap) is sized from it: the suspect is now per render
target state, the virtual heap (VHEAP) or macrotile array/list, which is
set up when a target is created and seems to advance with every scene.
Next: `G9P_PMDUMP=N` (Mesa) prints the first words of a render target's
VHEAP/RTC and macrotile array every Nth render.

`G9P_PMDUMP=5` (Mesa `671553e40a6`, the buffers allocated CPU-mapped),
busy session, 1985 renders without a hang: the first 64 bytes of every
render target's VHEAP/RTC buffer and macrotile array stay zero in all 794
dumps, so the firmware does not keep its per-scene PM state in Mesa's
buffers (or not at their start). Mesa's `rt_data_idx` is always 1 on the
G9P path (Rogue alternates two data sets per scene). Renders before a hang
vary widely (157, 369, 459, 1073, 3473, none in 1985), which fits state
that builds up unevenly. Guessing per structure is slow (a reboot per
hang); the direct way is an iPadOS capture of consecutive frames of one
render target, diffing what the kext writes per scene.

### Two hangs, not one (2026-11-01)

- **Heavy scenes run out of parameter memory.** One 1536x2048 render of
  vk-tri with `TRI_DRAWS=1000` passes, 3000 hangs its geometry job. With
  `apple_pm_trace` the light scene's events are `1 2 ... 00000445 00600000`
  (geometry; 0x445 = 1093 pages, about 4.4 MB) and `1 4 ...` (fragment);
  the heavy one posts none. The geometry microsequence is StartTA, Wait
  (TA_FINISHED | TA_TERMINATE | PM_OUT_OF_MEMORY), FinalizeTA, End: on out
  of memory it finalizes a scene that has not finished. iPadOS presumably
  branches into a partial render (the kext's encodePartialRenderSetup) and
  resumes the TA. Fix: partial renders; stopgap: a larger free list.
- **Hyprland's hang is a fragment job** whose geometry finished, in light
  scenes (about 167 pages). Not explained yet. Firmware mailbox messages
  are logged with `modprobe powervr dyndbg=+p` (they are dev_dbg); next a
  Hyprland session with `apple_pm_trace` (events) and dyndbg from boot.

### The hang fixed (2026-11-01)

With firmware messages visible (`modprobe powervr dyndbg=+p`), Hyprland's
hang is a **GFX firmware crash**; its crash log's registers point at the
Start3D path loading the free list's registration (fw 0x16634, current id
0x8df60), the crash RENDER.md describes for a fragment job without its
geometry state. A fragment job's retirement unregisters free list 0 and the
next geometry job registers it; the kernel dispatched the next geometry job
once the fragment ring's index advanced, which is before the retirement, so
the registration was cleared under the next fragment job now and then.
Geometry jobs now also wait for the firmware's fragment-done event (orchard
`a48a98a`). Busy sessions (`mesa/hyprland-busy.lua`, `hypr-session.sh`
SECS=150): 3 x about 3170 renders, no hang (before: within 30-130 s);
`hypr-once.sh` 11 x 20 s: no timeouts. The Mesa render ordering is gone
again (fork `ba304d33f58`).

Still open: heavy scenes running out of parameter memory (above; partial
renders). Stopgap (fork `4ac3eedab44`): the shared free list is 32 MiB;
vk-tri at 1536x2048 with 3000 and 6000 draws of an eighth of the target
passes (3000 hung at 8 MiB). A scene beyond that still hangs the GPU
until reboot. Each Vulkan device (process) has its own list.

## Window borders (2026-11-01, Mesa fork `d1ab45daed3`, `7013b551398`)

Hyprland draws its window borders (a white 4-pixel band at scale 2,
`mesa/hyprland-test.lua`). Two changes:

1. **Registers above r31** (ISA.md "Registers above r31"). When code
   generation runs out of r0-r31, the fragment compiler gives the NIR
   register (else the SSA value) live there with the furthest last use a
   home above r31 and generates again: stored after each definition,
   reloaded into a temporary for each use; the task's temp count covers
   the homes. Discards nested in control flow set a flag, ended by one
   discard. The border shader compiles to 116 registers and 22 KB of
   code; `press*.frag` tests (56-118 registers, loops and arrays) give
   exact results in vk-tri.
2. **Discard in blending shaders keeps the tile's colour.** The compiled
   border shader drew right in vk-tri, alone, with Hyprland's own SPIR-V and
   uniform buffer (`G9P_DEBUG=1 G9P_DUMP_FULL=1` dumps it; `vk-tri
   TRI_UBO_FILE`), and blending, loading, full size, flipping and
   scissoring. In Hyprland the border was missing in most 32x32 tiles, which
   tiles changing from frame to frame. Ruled out on the device:
   - Synchronisation: `G9P_SYNC`, waiting for all GPU work before the
     CPU transfers, never reusing command buffer uploads, and the target
     changing after its fence signalled (0 of 64 checked renders).
   - The common store: chunked uniform DMAs and a larger common store
     size; showing the uniforms as colour gave the right values in every
     tile.
   - The other draws: dropping the window and background pipelines.
   - The task's temp count: raising it to 128.

   With the discard compiled out every tile computed the right colour; with
   it even a constant colour was lost. So in the translucent pass (pass type
   1) the hardware discard drops pixels it should keep when other objects
   share the tile. A shader that reads the tile anyway now stores the tile's
   value where a pixel is discarded: the colour stores move to the end,
   selected on all discard conditions (`discards_to_select()`). Shaders
   with discards or colour stores inside control flow keep the hardware
   discard. Opaque discarding shaders (pass type 4) are unchanged.

Checks: vk-suite and the fragment op tests pass; vk-tri discard with
blending (also full size, loaded) passes; a 180 s busy Hyprland session
(`hypr-session.sh` SECS=180 BUSY=1): 2063 renders, no hang.

### Hyprland's effects (2026-11-01, Mesa fork `b8c3dec72cf`, `2f09119a9bc`)

`mesa/hyprland-full.lua` turns on rounding (10), translucent windows,
shadows, blur and animations, with two foot windows. All of it renders
(shadows around the windows, rounded corners) after two fixes. Blur was
first counted among them wrongly: the softened edges came from the 512
pixel test wallpaper being scaled up. See "The effects demo" below for
what blur needs.

- **Computed texture coordinates** (the blur shaders sample at offsets):
  copied to r0-r1, where the sample reads them (RENDER.md "Textures in
  Mesa").
- **View swizzles**: Zink samples GL's BGRA textures (wallpaper, client
  buffers, cursor) through RGBA8 views swizzled B, G, R, A; the image state
  ignored it, so red and blue were swapped. The 8-bit swap is now the
  other byte order's format; other swizzles are logged.

Debian's Hyprland ships no wallpaper images: `mesa/test-wallpaper.py`
writes a checkerboard to push as `/run/sid/usr/share/hypr/wall0.png`
(with `disable_hyprland_logo = false`); its edges show blur and its
colours show swaps. Busy session with all effects (150 s): 1596 renders,
no hang. Not yet: the depth/stencil format `D24_UNORM_S8_UINT` (logged,
not needed for these effects).

### CPU transfers (2026-11-01, fork `pvr_arch_g9p_transfer.c`)

Copies to and from twiddled images computed each texel's interleaved
index bit by bit: a 1536x2048 upload took 88 ms, foot's 1448x966 window
40 ms. The index is a column part plus a row part, now looked up from
per-copy tables, with word copies for same-format 32-bit texels: 9-17 ms
and 4-5 ms. In the measured sessions transfers came at window maps and
the wallpaper (about 0.6 s of CPU in the first 10 s, none after); whether
a constantly updating shm client adds per-frame uploads is not measured
yet. `vk-tri TRI_TEX=linear TRI_TEX_SIZE=300x200` and `TRI_LOAD=3`
fail with and without this change (known gaps: linear non-power-of-two
textures, a load after a clear-only pass).

Lesson: `deploy-zink.sh` installs the last build (`--no-rebuild`);
driver changes need `push-vk-zink.sh`, which builds. Experiments run with
the old build gave a false "fix" here first. Judge a border by whole
columns of tiles over several frames: one pixel row tells nothing when tiles
differ.

### The effects demo (2026-11-01)

`mesa/hypr-demo.sh SECONDS` (pushed by `setup-device.sh` with
`hyprland-demo.lua`, `demo-term.sh` and `demo-wallpaper.py`'s wallpaper)
plays window actions through `hyprctl dispatch`, which in Hyprland 0.57
takes Lua (`'hl.dsp.window.move({ x = 40, y = 360 })'`); `hyprctl` needs
`HYPRLAND_INSTANCE_SIGNATURE` from the chroot's `/run/user/0/hypr`.

- **Blur**: the GPU side works (`G9P_GRAB` of the blur chain: prepare,
  three passes down, three up, finish; all blurred). Hyprland 0.57
  blurred nothing behind foot windows, whether they were translucent by
  window opacity or by foot's own alpha, until foot asked for it with
  `colors-dark.blur=yes` (ext-background-effect), as Omarchy's foot theme
  does. With it the background behind the windows is blurred.
- **Blur behind foot needs window opacity below 1**: Hyprland treats
  foot's see-through buffer as opaque, so the focused window (opacity 1)
  got no blur and the others (0.9) did; the Jade Horse config sets 0.97.
- **The precomputed blur raced the wallpaper**: Hyprland computes its
  cached blurred wallpaper (`new_optimizations`) once the first
  translucent windows are up and keeps it. The demo's startup windows came
  before Hyprland's asynchronous loader had the wallpaper (the 4.6 MB Jade
  Horse PNG): the cache then held the empty screen, black or (when the
  wallpaper arrived in between) unblurred. With the 1-2 ms job checks it
  usually lost the race the other way; `G9P_SYNC=1` hid it the same way.
  Windows opened 8 s after start, or `hyprctl reload` after startup (blur
  options invalidate the cache), blur correctly every time;
  `hypr-demo.sh` reloads. A fragment fence that also waited for the
  fragment-done event did not change this race (such a fence was added
  later anyway, for the display: 40bae56). Jade Horse demo,
  render time per frame about 30 ms.
- **Speed**: an empty render cost about 4 ms whatever its size, in steps of
  2 ms: the kernel noticed finished jobs from a jiffy-based delayed work,
  and a render waits twice (geometry, then fragment). Checked every 100 us
  from an hrtimer (`apple_poll_us`) and on every firmware message:
  `vk-tri TRI_REPEAT=50` empty 4.3 -> 0.65 ms, full-screen 4.2 -> 2.2 ms,
  with a load 10.3 -> 5.3 ms.
- **Where a frame goes** (`G9P_SYNC=1 G9P_TIME=1`): the composite render
  (all windows, 35 draws) has 44-88 ms of fragment time; the copy to the
  scanout buffer 3.3 ms, blur passes about 3 ms, geometry under 2 ms.
  Static scene, three windows, composite fragment time: all effects 47 ms,
  no shadow 27, also no border 11.5, also no rounding 4.1 (shadow range 8
  instead of 30: 41). The border and shadow shaders compile to 30 and 23
  KB with 123 and 118 registers (about 1000 and 840 NIR operations, 70
  branches each); both cover each window's whole box. They are what the
  compiler has to make faster.
- **A hang** in the first 180 s demo (geometry job, Hyprland stuck in the
  driver) did not come back in a second 180 s run on a fresh boot; the
  first ran with about 500 MB of debugging files in RAM. Zink logs
  `vkMapMemory failed` once per run in both.


### Live blur at 60 fps (2026-11-01, Mesa fork `b15b5418b76`, `b9721ab4b49`)

The Jade Horse demo blurs live again (`hyprland-jade.lua`, Omarchy's glass
settings, no xray). A window moving over the others holds 60 fps: 619 of
619 frame intervals under 20 ms (`blurtest.sh`-style runs: one window
floated over the tiled ones and moved every 0.25 s). Three steps:

- **GPU clock**: the driver powered the GPU on in its lowest performance
  state (FENDER.md section 9); state 6 took a live-blur frame from 33 to
  19 ms.
- **What the frame waits for**: a kernel timeline of job writes and fence
  signals (bring-up only, not kept) showed the CPU hand-offs between jobs
  at 15-30 us, and each frame's ten renders (composite, the blur chain,
  the copy to scanout) running back to back in about 10.6 ms. Frames were
  late whenever that chain ended more than about 11 ms after it started:
  Zink submits a frame only once Hyprland has recorded all of it, so the
  CPU time per frame comes before the GPU's, not beside it.
- **CPU per frame**: `perf` (Debian's `linux-perf`, copied into the
  chroot) showed a third of Hyprland's CPU time in our Vulkan driver,
  mostly the NIR/PCO compiler. Every `vkCmdBeginRendering` (Zink renders
  dynamically) set up Rogue's SPM end-of-tile and background programs and
  its load-op programs, two shader compiles and buffer allocations per
  render. G9P needs neither (no SPM; loads and clears are its background
  object); skipping them cut Hyprland's CPU time per frame by a quarter.

Render areas were checked on the way (G9P_TRACE prints them, the tiles the
draws cover, and the load op): Hyprland's blur renders cover the whole
screen with a clear load op, so the clear must reach every tile; only
don't-care renders skip empty tiles now, which changed little.

A grab mid-way through a slow (5 s) window resize showed the moving
window's text twice: swapped sampler bits, fixed below ("Resize glitch").

### Resize glitch: sampler bits swapped (2026-11-01, Mesa fork `3ca781076f4`)

A window resizing slowly (a 5 s `windowsMove` animation) showed its text
twice. Hyprland draws a buffer that is smaller than its animated box with
texture coordinates past 1 (`render:expand_undersized_textures`), relying
on clamp-to-edge. Ruled out on the way: tile skipping (`G9P_ALL_TILES=1`),
stale damage (`debug:damage_tracking = 0`), the blur's second texture
(blur off), twiddled padding and linear layouts (vk-tri past the edges).
`expand_undersized_textures = false` removed it, and vk-tri reproduced it
only with a linear filter past v = 1: the sampler packing had linear
minification and V repeat swapped (dword 1 bit 0 is V repeat, dword 0 bit
25 minification), so every linear-filtered texture repeated vertically.
`vk-tri TRI_WRAP=repeat` now checks repeat; vk-tri's linear textures use
the driver's row pitch (a leftover `4 * width` broke widths whose rows are
not 64-byte aligned). The tiled window that seemed cut off in the same
grabs is its box still growing: correct.

## Instanced draws and the geometry hang (2026-11-02, Mesa fork `f9621d81ba5`, `93544a9772e`)

- **Instance index:** the vertex kick's temps q0 holds the vertex index in its
  low half and the instance index in its high half. A second DOUTW with
  control `0x80002001` (Rogue: destination r1 at bit 13, BSIZE upper) writes
  the instance index into r1, as iPadOS's `instanced` capture does. Vertex
  shaders keep r0-r1 pinned; per-instance bindings index with r1. Divisors
  other than 1 and a nonzero firstInstance are refused.
- **The geometry hang of glmark2 `shading`/`build` and of instanced draws**
  was VDM_STATE5's MAX_INSTANCES (bits 25-29, 0 = 32 instances per vertex
  task). With 32, a vertex task of a 14-register shader never finishes:
  the firmware runs StartTA, TA_FINISHED never comes, and the geometry job
  stalls deterministically for a given submission rhythm (10 instances:
  render 73 after a firmware start; 1000: within a few renders).
  `pvr-tri TRI_INSTANCES=1000 TRI_REPEAT=300`, three runs each: VDM_STATE5
  `0x1081` (8 registers) x 32 and `0x1c81` (14) x 4/8/16 pass, `0x1c81` x 32
  hangs by render 17. The fork keeps registers x instances at 256.
- **Ruled out on the way** (heap and window dumps per batch, register reads
  during the stall, the firmware trace): free-list order and size, a lost
  doorbell (a second one does nothing), the shared scheduling entry
  (rotating entries changes nothing), clock scaling, runtime PM, Fender
  power, and firmware counters.
- **iPadOS reference:** `ios-capture` `GC_INSTANCES`/`GC_REPEAT` render N
  times before the captured one. iPadOS renders 1000 instances 100 times
  (about 1 ms each), and render 101 differs from render 1 only in stamps:
  nothing per render or per instance count beyond the INDEX_LIST word.
- **Firmware trace on a hang:** `apple_fw_debug=3` (writable; applies from
  the next GPU reset) makes the hang report end with the SKU ring's last 24
  records. A good geometry job: `0x111` dispatch, `0x102`/`0x103`, `0x000`
  StartTA, `0x112`, event `0x102` (group 3, mask 0x80000000, events 0x20 =
  TA_FINISHED), `0x001` FinalizeTA. The stalled one ends in `0x113 (1, 2)`.

## The GPU desktop against pixman (2026-11-02)

`tools/a10/arch/desktop-bench/run.sh`, run over SSH as the session user in
a logged-in Omarchy A session, runs one workload on whichever renderer
Labwc uses: 20 s idle, foot printing for 20 s, then Firefox on a fresh
profile loading a dashboard page (600 cards with canvas charts), scrolling a
long article and animating 60 cards, 20 s each. In-page
`requestAnimationFrame` probes post frame times to a local collector. The
pixman pass moves the Vulkan ICD aside so the login session falls back.

| | GPU (`93544a9772e`) | GPU, linear images (`6a47d530a13`) | pixman |
|---|---|---|---|
| foot 20 s: Labwc CPU, lines | 5.1 s, 4.03 M | 3.4 s, 3.86 M | 1.1 s, 3.26 M |
| Firefox load | 1654 ms, p99 128 ms | 1414 ms, p99 112 ms | 1437 ms, p99 51 ms |
| Scroll: p95 / p99, frames > 25 ms | 27 / 38 ms, 63 | 19 / 26 ms, 12 | 18 / 19 ms, 3 |
| Animation: p95, frames > 25 ms | 25 ms, 53 | 22 ms, 32 | 19 ms, 14 |
| Firefox phase: Labwc CPU | 13.3 s | 9.0 s | 3.2 s |
| Lowest free memory (from ~1.1 GB) | 180 MB | 138 MB | 374 MB |

With `VK_EXT_host_image_copy` (`6ccd31a3e03`, 2026-11-03; Zink uploads window
contents straight into the image, no staging buffer): foot 20 s Labwc 2.2 s,
Firefox phase Labwc 4.9 s, scroll p95/p99 18/26 ms (12 frames > 25 ms),
animation p95/p99 18/21 ms (10 frames > 25 ms, pixman 14), load 1484 ms,
Firefox RSS peak 754 MB, lowest free memory 255 MB (pixman 374 MB). Still
behind pixman: Labwc's CPU (about 1.5x) and about 120 MB of memory.

**Where the memory goes** (2026-11-03): the GPU session starts with ~75 MB
less free memory than pixman. Labwc's own PSS is 26 MB; the difference is
pinned GPU memory (Shmem/Unevictable 146 MB at idle). One Vulkan device
pins about 36 MB (vk-tri: +36 MB while it runs), mostly the 32 MiB
parameter buffer every device allocates (`G9P_FREE_LIST_SIZE`), and Labwc
holds the render node 7 times (Zink's devices). The A10 firmware runs one
geometry scene at a time and the kernel serialises them, so one shared
parameter buffer in the kernel can serve every device: next step.

Shared pool (kernel `pvr_apple_pm_pages()`, worktree commit `d943f57`): every
device made two free lists (Mesa's global one, created first, and the 32 MiB
G9P list), now both hand out pages of one 32 MiB pool. A second Vulkan device
pins 2 MB instead of 36. Benchmark: the session starts with 1158 MB free
(pixman 1154), shared memory during Firefox +175 MB (pixman +205); lowest free
memory 223 MB (pixman 374, from a start 110 MB lower: one run each, to repeat).

Three alternating runs each (2026-11-03, orchard main `b5cbeed` kernel with
the shared pool, Mesa `6ccd31a3e03`; the loop logs in through a uinput
keyboard, so every run starts from a fresh session):

| | GPU (gles2) | pixman |
|---|---|---|
| Free after login | 1080-1141 MB | 1155-1213 MB |
| Shmem at idle | 126-129 MB | 72-82 MB |
| foot 20 s: lines, Labwc CPU | 3.83 M, 2.2-2.3 s | 3.30 M, 1.1 s |
| Firefox phase: Labwc CPU | 4.8-5.1 s | 3.3 s |
| Firefox: shmem growth | +181 to +202 MB | +176 to +185 MB |
| Firefox: lowest free memory | 193-276 MB | 248-320 MB |
| Load / scroll / animation fps | 52-54 / 59.5 / 57-59 | 52-55 / 59-60 / 56-58 |

Frame rates are level; the one-run "same free memory at start" did not hold
up. The GPU session still pins about 50 MB more shared memory from login on
(70-80 MB less free) and Labwc spends 1.5-2x pixman's CPU. Those two are
what is left before the GPU desktop beats pixman.

**Zero-copy shared memory** (2026-11-03): the copy into textures was the
CPU gap (perf: `memcpy` 45% of Labwc while foot prints, 54% while Firefox
runs). omarchy-a's wlroots (patch 0002) turns each shared-memory buffer of
a sealed memfd into a DMA-BUF of its pages with udmabuf (orchard kernel
`CONFIG_UDMABUF=y`, plus `drivers/dma-buf/0001` for a buffer that ends in
the file's last 16 KiB page, which is most of Firefox's), and the GLES2
renderer imports it; Mesa imports a linear plane at an offset (fork
`2d2e29774ee`). Earlier the same day, render-target datasets are reused
across dynamic-rendering passes (fork `7c16226c9b4`): the kernel share of
Labwc's time fell from 19% to 12%.

| Three runs each | GPU | pixman |
|---|---|---|
| foot 20 s: Labwc CPU, lines | 1.0 s, 3.48-3.69 M | 1.1 s, 3.22-3.26 M |
| Firefox phase: Labwc CPU | 2.5 s | 3.4-3.5 s |
| Labwc RSS | 27 MB | 37-49 MB |
| Free after login | 1082-1096 MB | 1148-1183 MB |
| Firefox: lowest free | 251-318 MB | 356-370 MB |
| Firefox's own CPU | 54.9-55.0 s | 51.5-52.8 s |

Labwc now beats pixman; frame rates are level. Open: memory (the 32 MiB
parameter pool, a third 12 MB swapchain buffer, Zink) and Firefox's own
CPU, about 3 s more because the session's `MESA_LOADER_DRIVER_OVERRIDE=zink`
gives it Zink on the GPU instead of llvmpipe.

**Where the GPU session's memory goes** (2026-11-03, a temporary powervr
build logging every buffer of 256 KiB or more, plus fdinfo): at the
greeter (no GPU client) 18 MB unevictable, in an idle Labwc session 108 MB.
The difference: the kernel's 32 MiB parameter pool; the two 12 MB
swapchain buffers (GBM on the display node, LINEAR, exported to the
display: pixman has those too); a 12 MB GPU-only buffer, the SPM scratch
buffer every render state allocates at framebuffer size, unused on G9P
and gone with fork `73a49abe247`; another 12 MB CPU-mappable buffer:
Zink's staging buffer for one `glReadPixels` of the whole screen, kept in
its buffer cache afterwards. The reader is omarchy-a's readiness check: at
login the shell runs `/usr/libexec/omarchy-desktop-ready`, which captures a
frame with `grim -t ppm /dev/null` (found with `sched:sched_process_exec`
during login: greetd → login-session → labwc → qs → omarchy-desktop-ready
→ grim, and a wlroots build with symbols: `gles2_texture_read_pixels` ←
`wlr_ext_image_copy_capture_frame_v1_copy_buffer`). Pixman reads memory
directly and pays nothing. Fix belongs in the check (attest the frame
without reading a whole one back, e.g. presentation feedback), an
omarchy-a decision. About 6 MB of Zink and Mesa buffers remain. A bare Zink client (eglinfo) allocates 2.5 MB.
Tools: `perf probe -x /usr/lib/libvulkan_powervr_mesa.so 'pvrbo=0x<offset of
pvr_drm_winsys_buffer_create> size=%x1:u64'` with `--filter
'size==12582912' --call-graph dwarf` (the kernel has uprobes, no kprobes).

## Zero-copy shared memory: the recipe (for any compositor)

Clients that draw on the CPU (foot, Qt Quick software, GTK, Firefox's
software WebRender) hand the compositor `wl_shm` buffers. A GPU compositor
normally uploads each into a texture: a copy per frame (the main CPU cost
here) and a second copy of every surface in GPU memory. Instead:

1. **Kernel** (orchard): `CONFIG_UDMABUF=y` (a bool), and
   `kernel/patches/drivers/dma-buf/0001`: udmabuf takes a memfd's last,
   partial page. With 16 KiB pages most buffers end inside one; upstream
   udmabuf refuses that range (EINVAL). `/dev/udmabuf` is tagged `uaccess`
   by systemd, so the logged-in user can open it.
2. **Mesa** (fork): import a linear DMA-BUF whose plane starts inside the
   memory (`2d2e29774ee`; the plane offset is the buffer's offset within its
   first page) and fail an unsupported import cleanly instead of asserting.
   Row pitch: G9P wants 64-byte multiples (16 pixels of XRGB8888), which
   full-width windows meet; others fail the import and are copied.
3. **Compositor**, per `wl_shm` buffer, on first use:
   - only if the pool's fd is a memfd sealed with `F_SEAL_SHRINK` (Qt, GTK,
     foot and Firefox do; GTK's own `gdk-wayland` pool is not, it gets
     copied);
   - `UDMABUF_CREATE` over the buffer's own pages only (offset rounded down,
     end rounded up to the page size): a pool can be large and sparse (foot
     reserves one to scroll in) and udmabuf pins everything it covers. A
     whole-pool udmabuf pinned 1 GB for one foot window here;
   - describe the buffer as a one-plane LINEAR DMA-BUF (`offset` = its offset
     in the first page, `stride` as the client gave it) and import it like a
     client DMA-BUF (EGLImage);
   - keep the buffer locked while a texture samples it, as for DMA-BUF
     clients: do not release it after "uploading";
   - close the udmabuf when the buffer is destroyed;
   - if the import fails, copy as before (and stop trying for a while).

   wlroots: omarchy-a `desktop/packages/wlroots0.20/0002` (in
   `types/wlr_shm.c` the buffer gets `get_dmabuf`; the GLES2 renderer
   already prefers DMA-BUFs and gains the fallback). **Hyprland** does not
   use wlroots' buffer code: the same steps belong where Aquamarine/Hyprland
   turn a `wl_shm` buffer into a texture (its shm buffer type's dmabuf
   attributes, or the renderer's shm texture path).
4. **Coherence**: the A10 GPU sees what the CPU wrote to cached memory
   (apple_cpu_cached experiment: 300 texture uploads and the suite without
   cache maintenance). On a GPU without that, the compositor would need a
   `DMA_BUF_IOCTL_SYNC` per commit, which costs about as much as the copy.

Measure with fdinfo (`drm-shared-memory` counts the imports, which are the
clients' own pages) and `ls -l /proc/<compositor>/fd | grep dmabuf`.

## Conformance and ES 3 (2026-11-03)

No dEQP or Vulkan CTS run yet. On the A10, Zink offers OpenGL ES 2.0 and
desktop GL 2.1 (`eglinfo -B`). Mesa's ES 3.0 check (`compute_version_es2`)
fails only on texture formats the G9P format table does not decode yet:
float and half-float textures, RG, integer, snorm, RGB9E5, R11G11B10,
32-bit float depth and RGB10A2UI. Transform feedback, instancing, four
colour attachments, sRGB and primitive restart are there.

Compiler gaps (the "not supported yet" paths of `g9p_compile.c` and
`pvr_arch_g9p_gfx.c`): derivatives (the theme and background pickers run on
llvmpipe because of them), discard inside control flow, some fragment
inputs and outputs, subpass input loads, register spilling (above 32
registers), UBOs and dynamic buffers, 16-bit registers, workgroup ID z,
indirect dispatch and base groups, `firstInstance`, some vertex formats and
divisors, sampler address modes. No partial renders: a scene that runs out
of parameter memory hangs the GPU (hence the 32 MiB pool). Quickshell on
the GPU hung the A10 on 2026-11-02 (cause unknown); the shell stays on
Qt's software renderer.

## Roadmap (2026-11-03)

1. Ship: memory below pixman (third swapchain buffer, Zink overhead, the
   pool after 3), which processes get GL on the GPU, push the set, GPU
   session as the A10 default with fallback to pixman.
2. Measure: dEQP-GLES2, dEQP-GLES3 through Zink and core dEQP-VK groups on
   the device; report only what G9P compiles, so applications fall back.
3. Robustness: partial renders (then a smaller pool), the Quickshell hang,
   recovery that keeps the session.
4. Completeness, from 2's failures: texture formats (ES 3.0), derivatives,
   discard in control flow, render targets, spilling, then UBOs, 16-bit,
   subpass inputs; compute for ES 3.1.
5. Performance: compiler quality (about 2x behind Apple's on the Julia
   effect), cached mappings, fewer ioctls per frame, GPU power states.
6. Other A-chips (J71t first), with captures per generation.
7. Upstream: kernel GPU series, udmabuf's last page, wlroots'
   shared-memory DMA-BUFs.

The user's yardstick: YouTube in Firefox loads, renders and plays
smoothly. Video is decoded in software (720p is the realistic target, H.264
cheapest); the work here is presenting decoded frames without copies and
keeping memory down. Hardware video decode (Apple's decoder block) is out of
scope for the first release, after suspend/resume.

Video phase (`desktop-bench/run-video.sh`, clips from `make-clips.sh`; two
runs each, 2026-11-03): both renderers play VP9 720p, H.264 720p and VP9
1080p at 30 fps (1-2% dropped at 720p, none at 1080p), so software decode
keeps up at 30 fps. Labwc 3.7 s either way; Firefox 58.6-59.1 s on the GPU,
56.8-56.9 s on pixman; lowest free memory 209-218 MB against 291-322 MB.
In the GPU session Firefox on llvmpipe instead of Zink saves about 1 s of
its CPU and 40 MB (two runs each), not the whole gap to pixman.

- **The first cost was uploads:** perf over a scrolling Firefox window put
  15% of all CPU time in the driver's CPU transfer (`copy` in
  `pvr_arch_g9p_transfer.c`), twiddling each window texture texel by texel
  as Zink uploads it. Single-level 2D colour images are now linear on G9P,
  so an upload is a row `memcpy`.
- **Cached CPU mappings change little:** a module parameter mapping userspace
  buffers cached (experiment, not committed) passed every coherence check
  (suite x3, compute, pvr-tri, 300 texture uploads) but moved Labwc only
  from 13.3 s to 12.7 s.
- **Still behind pixman:** Labwc's CPU (about 3x) and memory (about 240 MB
  more at the low point; a run with 390 MB of test leftovers in `/tmp`, which
  is RAM, hit the OOM killer). Next: profile the remaining Labwc time and
  account the extra memory per process.
- vk-tri reads its target back through `vkCmdCopyImageToBuffer` and uploads
  its texture through `vkCmdCopyBufferToImage`: an optimal image's layout is
  the driver's to choose.
