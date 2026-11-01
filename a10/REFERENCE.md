# A10 GPU vs. existing driver stacks

Updated 2026-10-29 through hardware experiment **69**. Hardware results and
reproduction commands: [COMPUTE.md](COMPUTE.md). Firmware and power bring-up:
[FENDER.md](FENDER.md). Summary: [README.md](FIRST-LOOK.md).

## Established, inferred, and unproven

- **Established:** Apple's GFX firmware runs on an ARM32 A7 IOP and speaks RTKit
  plus AGX endpoints and rings. Real core power-up and RGX register access work.
  CORE_ID = `0x011b0602`; legacy CORE_REVISION = `0x000d0a00`.
- **Established:** compute submission end to end. A terminate-only stream
  completes (46). A native shader runs (66; fetch-fault control 67). A native
  `store_marker` kernel writes `0x1357` to a bound buffer (68); moving the
  binding moves the write (69).
- **Established, the fixed-function side is Rogue:** Apple's PDS programs use the
  Rogue encodings of Mesa's `pvr_rogue_pds_defs.h` (HALT, BRA, DOUTD, DOUTW,
  DOUTU; DOUT CC = bit 27, END = bit 26). CDM kernel words match Mesa's
  `cdm.xml` (`k0`–`k5`, `k8`), except that A10 records carry one more zero word
  (8 words). Page tables are Rogue PC/PD/PT, supplied through the physical root
  array. The stream register is RGX+0x480; the terminate is `0x80000000`.
- **Established, the shader core is not Rogue (see below).**
- **Established, the dispatch recipe:** captured from iPadOS 17.7 with
  `ios-capture/`. Each dispatch is a DMA-only PDS task that loads the buffer
  binding into the USC common store, then the kernel record. PDS exec base =
  USC code base = 0x300000000 (kext P+0x10/+0x18).
- **Unproven:** multi-thread dispatch (thread/workgroup IDs), rendering (TA/3D
  firmware paths), full feature/quirk identity, Vulkan, OpenGL, an accelerated
  desktop.

## Shader ISA: Apple, not Rogue

Native A10 USC code comes from Xcode's Metal toolchain
(`metal-tt -arch applegpu_g9p`) and is byte-identical to what iPadOS loads. It
does not parse as Rogue instruction groups (`pco_isa.py`): there is no end
group, groups have impossible lengths, and the chain overruns the program. The
code is 16-bit aligned, pads with `0xc000` and ends with `0x8000`. Rogue pads
with `0xff`/`0xf0|n` and ends with a control group (third byte `0xee` for
`nop.end`). Mesa's `pco` also targets 6XT (GX6250), so this is not a generation
difference. The A10 pairs Rogue fixed-function hardware with an Apple shader
core.

Consequence: Mesa's `pco` cannot produce A10 shaders. A G9P backend is needed,
an encoder documented from `metal-tt` output. The remaining Mesa pvr pieces
stay reusable: state setup, control-stream packing (`csbgen`) and PDS generation.

## Upstream kernel (`drivers/gpu/drm/imagination`)

| Part | Relevance to A10 |
|---|---|
| `pvr_rogue_cr_defs.h`, `pvr_rogue_defs.h` | Register and field reference. Distinguish legacy ID/revision from newer packed BVNC. |
| `pvr_rogue_mmu_defs.h`, `pvr_mmu.c` | Page-table format matches the tested mappings. Reference for the VM layer. |
| `pvr_fw*.c`, `pvr_ccb.c`, `pvr_queue.c`, `pvr_rogue_fwif*.h` | Not Apple's protocol (IMG KCCB/FWCCB, META/MIPS/RISC-V). Apple's side is RTKit + AGX rings, documented in FENDER.md/COMPUTE.md. |
| IMG firmware device-info header | Absent from Apple's image. The A10 needs a static device-info entry. |
| `pvr_drm.h` UAPI / GEM / VM | Option for the userspace interface: Mesa's pvr winsys would work unchanged, but the kernel would translate pvr job streams into Apple firmware commands. Decision pending. |

Driver shape: a new DRM driver structured like `drm/imagination`. It uses
mainline `apple-rtkit` with the `apple,t8010-a7iop-mailbox` backend, GEM shmem,
`drm_gpuvm`, `drm_sched` and an Apple firmware backend (init data, rings,
mapping ring, doorbell on EP 0x21, CDM/PDS command construction). Asahi's AGX
driver is a design reference only: it is Rust, and Asahi's policy bars LLM
contributions.

## Mesa

| Part | Relevance |
|---|---|
| `src/imagination/pco/` | Not usable for A10 shaders (ISA differs). |
| `src/imagination/pdsc/`, `vulkan/pds/` | PDS encodings match the hardware; reusable. |
| `src/imagination/csbgen/rogue/` | CDM fields match; A10 needs the 8-word record. |
| `src/imagination/common/device_info/` | Needs an A10 entry with real feature and quirk values. |
| `src/imagination/vulkan/winsys/` | Reusable if the kernel exposes the powervr UAPI. |
| Zink | OpenGL on top of a working Vulkan driver. |

Local comparison source is pinned at Mesa mirror commit
`1c3a936490f9f0951188218e136cd03bca497386` under `out/reference/mesa`. No Mesa
code has been modified or submitted.

**Contribution policy:** Mesa's PowerVR README declines LLM-generated
contributions. Mesa-side work stays in a fork until human authors take it
upstream.

## Next, in order

1. **Render capture on iOS:** a triangle into a texture with `ios-capture`. This
   gives the TA/3D firmware commands, so the driver's submission covers both
   engines.
2. **Kernel driver:** firmware boot, init data, GPU VM, compute submission
   (proven), then render. Decide the UAPI (powervr-compatible or our own) first.
3. **G9P shader encoder:** characterize the ISA from `metal-tt` output.
4. **Mesa fork:** pvr with a G9P backend, then Vulkan, Zink and the desktop.
