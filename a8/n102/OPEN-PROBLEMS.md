# A8 open problems

What does not work yet on the iPod touch 6, what is known about each, and what is not. Tags as in
[README.md](README.md#evidence-levels).

## The PM-id kernel (validated)

- **[HW]** On the kernel with one PM id per VM ([BRINGUP.md](BRINGUP.md#pm-id-per-vm)), every run was clean (no
  firmware or MMU fault, no hang, no lost job): two headless vkmark clients at once (299 + 297 fps); one client
  with a 61-block pool (611 fps); 32- and 61-block clients side by side, alternating PM ids (330 + 344 fps); vkmark
  on Wayland at 320x568 (633 fps) and at panel size with direct scanout (502 fps); 61- and 16-block clients next to
  the compositor (463 / 461 fps); the full vkmark suite on Wayland at 640x1136 (score 432, every scene).
- **[HW]** An earlier run that looked like a device stop was the system's idle suspend (lock at 62 s, suspend at
  72 s); the device resumed on the same boot.
- **[KC]** 61-block pools are legal: the save and load fields are 22 bits wide, the per-id state is one pointer,
  and Apple mixes pool sizes across PM ids.

### The earlier vkmark-on-Wayland fault

- **[HW]** Before the PM-id change, native Vulkan vkmark in the labwc session lost the GPU in its first scene (the
  GPU recovered, the desktop survived); headless vkmark and Qt through Zink ran clean. Two signatures: a colour-target
  write just past a buffer (the tile-row overrun in [MEMORY.md](MEMORY.md#colour-tile-padding)), and, after the pad
  fix, a tiler control-stream write near VA 0 in the PM's address space within the first few geometry jobs.
- **[KC]** That search found the real defect of every VM sharing PM id 0, now fixed. Its link to this fault would need
  differing pool sizes, and all those runs had 32-block pools, so the causation was never shown **[INF]**.

## Vertex textures

- **[HW]** Vertex-stage texture reads and samples have **never worked on the A8 GPU**: every one returns 0,0,0,0
  (RGBA8, RGBA32F, RGBA32I), while the same reads in fragment programs pass, with no GPU fault. Earlier "no failure"
  runs had no Zink override and ran on softpipe; they are void.
- **[HW]** With the A9's vertex form a vertex `textureLod` locked the TA. In one build with vertex textures on by
  default, the first run hit the firmware's lockup recovery and the GPU was reset (the desktop survived); a **second
  run in the same boot froze the whole SoC**, and the journal did not reach the disk. Vertex textures are off by
  default since.
- **[KC][iOS]** The leading candidate (offline, not proven on the GPU): the failing cases pass the fetched value to
  the fragment stage through a flat varying, and our compiler emits the A9's flat-load instruction, which no A8
  program uses ([SHADERS.md](SHADERS.md#varyings-iterators)). The "passing" controls never ran the vertex-to-varying
  path (the constant varying was folded into the fragment program). The vertex texture state itself matches Apple's
  in form.
- **Next:** emit Apple's A8 flat iterator, then fly Apple's captured vertex sample form (built, behind an opt-in) one
  case per process, smallest draws first, with timeouts and a kernel-log check. Still open: where the vertex
  constant level and the read sampler land in the common store.
- This is what keeps **Firefox's WebRender** from running fully on the A8 GPU: its vertex programs fetch the GPU
  cache, transforms and render-task data with `texelFetch`. Its fragment programs compile.

### The second-lockup freeze

- **[HW]** The A8 lockup path recovered once and then froze the SoC on a second lockup of a GPU that had already
  been reset once. Not root-caused. The next capture needs the live kernel log, which recovery arm fired, how far the
  reset got, whether the second reset differs (firmware reload, power and clocks) and any untimed register poll.
  Every A8 freeze that was root-caused came from register polling or power-up, never from shader contents.

## R8 load and cube arithmetic for Firefox

- **[iOS]** A load of an `R8_UNORM` target (WebRender's alpha and clip-mask targets) stays refused: Apple's load
  program is captured only for BGRA8 (a two-word emit), and R8 programs emit one word. A hand-made R8 load would be
  unwitnessed. Needed: one capture of an R8 target with load action Load. The capture tool has the pass.
- **[iOS]** A cube sample whose result feeds arithmetic stays refused; two WebRender pipelines need it. The likely
  form is the 32-bit-result cube sample, which has not been captured; the capture pass (a multiply the compiler
  cannot fold) is in the tool.
- **[HW]** Refused work is now skipped by default (the draw is lost, the command buffer is kept), because a refused
  program used to fail `vkEndCommandBuffer` and Firefox lost its GL context; `PVR_A8_STRICT=1` restores the failure,
  and each refusal reason is printed once.
- **[HW][INF]** A later Firefox crash (Aquarium, hardware WebRender) was in the CPU transfer path: several memory
  objects importing one dma-buf shared one CPU mapping, and freeing any one unmapped it for all. Reproduced in a test
  and fixed, but not yet in the Mesa pull request; that it was this crash is inferred.

## Still refused or missing

- 4x MSAA (the 4x TA state is uncaptured); sRGB targets (PBE gamma bits and the end-of-tile word); three or more
  colour targets; gradients, array samples and gather (register order unproven); explicit LOD or bias from buffers
  outside the fetch path; `texelFetch` above level 0 (opt-in only).
- Clears without a TA: each clear is still an empty TA plus a 3D job; Apple may skip the TA, and what selects
  Apple's 3D-only command is not known **[KC]**.
- No partial render and no context store, so a parameter-buffer overflow hangs the TA; no PM grow.
- `vkCmdBlitImage` stays a CPU transfer.
- The Vulkan ladder's `depth16` rung fails by design (no D16 on the A8, see [MEMORY.md](MEMORY.md)).
- Skip-empty-tiles does nothing on the A8 yet: the kernel writes its own `ISP_CTL`.

## Performance

- **[HW]** Per-job cost dominates: glmark2's desktop blur runs 11 serial TA+3D renders per frame at about 0.85 ms
  each, close to the fixed cost of one clear (1.66 ms from submit to fence). TA and 3D still run one after the other
  by default; two scenes in flight are designed but not landed.
- **[HW]** The firmware self-parks between jobs, which adds about 435 µs to each job that wakes it
  ([POWER.md](POWER.md#gpu-idle-power)), and the GPU is held at its lowest performance state (365 MHz).
