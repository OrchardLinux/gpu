# A8 open problems

What does not work yet on the iPod touch 6, what is known about each, and what is not. Tags as in
[README.md](README.md#evidence-levels).

## The Wayland stop on the PM-id kernel (under investigation)

**This is open and under investigation. Its cause is not known.**

- **[HW]** The run: on the kernel with one PM id per VM ([BRINGUP.md](BRINGUP.md#pm-id-per-vm)), headless vkmark
  next to labwc ran 20 s clean (551 fps, no faults). Then, with the PM pool raised to 61 blocks, vkmark on the
  Wayland window system at panel size (640x1136) stopped the device about 4 s in: the kernel log ends, the network
  goes silent, and there is no fault, hang or reset line. The pool was far from full (77 of 1952 pages used).
- **Known:**
  - **[KC]** 61 blocks is legal: the save and load fields are 22 bits wide, the per-id state is one pointer, and
    Apple mixes pool sizes across PM ids all the time. Our stack, list and control block hold 61 blocks.
  - **[HW]** A whole-SoC freeze is **not** established. The kernel was set to reboot at once on a panic, so a panic
    would look the same from outside, and what the screen showed was not recorded.
  - **[HW]** The run changed four things at once: the pool size, the window-system path, presentation at panel size
    (possibly direct scanout through the display DART) and the run length. Wayland vkmark had not rendered on this
    kernel before (an earlier step's pipeline had killed it), and only one VM was submitting.
  - **[HW]** A silent stop at the default pool of 32 had already happened once **before** the PM-id change, during a
    Zink client. It was never root-caused.
- **Candidates, most likely first [INF]:** (1) Wayland presentation at panel size: labwc scanning out vkmark's
  dma-bufs through the display DART, or GPU dma-buf sharing; (2) a kernel panic in a newly reached path; (3) the
  ungated doorbell writing the MTS while the GPU PLL relocks (rare; headless runs are clean); (4) a GPU stall followed
  by the timeout path's register read or reset locking the SoC; (5) the first high-rate save and load between PM
  ids; (6) the 61-block pool itself, for which no mechanism has been found.
- **Next:** a network console plus a synced on-disk heartbeat, then one change per run: two headless clients at 32
  blocks; 61 blocks headless; Wayland composited at a small size; Wayland at panel size and 32 blocks with the KMS
  state captured; then 61 and 16 blocks on Wayland.

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
