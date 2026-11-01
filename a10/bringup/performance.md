# A10 (T8010) GPU: performance, workflow and tools

Part of the bring-up guide (README.md).

## Performance: method and pitfalls

Make the frame fit in 16.7 ms by measuring where it goes, in this order:

1. **Frame intervals.** `mesa/hypr-bench.sh moves 40` (or `glide`) prints
   the intervals between frames from Mesa's `G9P_TRACE` and Hyprland's CPU
   time per frame. The figure that matters is the share under 20 ms.
2. **GPU time per render.** `hypr-bench.sh time 8` (`G9P_SYNC=1
   G9P_TIME=1`): geometry and fragment time of each render, by pipeline.
   Each render is waited for, so this is cost, not real speed.
3. **The chain and its deadline.** `tools/device/timeline.patch` (kernel
   job log) and `timeline.py`: how long a frame's renders run back to back
   and how late frames depend on that length. A sharp step (late frames
   from some chain length on) is the frame's real GPU budget.
4. **CPU.** `hypr-bench.sh profile` (perf in the chroot,
   `tools/device/perf-install.sh`): where Hyprland's CPU time goes.

**What the A10 measurements showed** (Hyprland, live blur, one window
moving over blurred windows, ten renders per frame):

| Step | Frame | Note |
|---|---|---|
| GPU in state 1 | 33 ms | GPU-bound |
| GPU in state 6 | 18.5-19 ms | chain of renders ~10.6 ms |
| no per-render shader compiles | 16.7 ms | 617 of 618 frames on time |

**Zink submits a frame only after the application has recorded all of
it**, so the CPU time per frame comes *before* the GPU's: CPU + GPU chain +
flip must fit in 16.7 ms. With a 10.6 ms chain the budget for CPU was
about 5 ms, and Hyprland took about 6.8 ms. A third of that was our Vulkan
driver compiling shaders on every `vkCmdBeginRendering` (see "Shared code
G9P must bypass"). After the fix Hyprland takes about 4.3 ms per frame;
perf now shows most of the remaining CPU time in the kernel (buffer
allocations), the next thing to look at.

**Ruled out, with numbers** (so nobody measures them again):

- CPU hand-offs between jobs: geometry done -> fragment written 17 us
  median, fragment done -> next geometry written 15 us (100 us hrtimer
  polling plus the scheduler). Not a cost.
- Clipping the blur passes to their render area: Hyprland's blur renders
  are full-screen *clears* (the clear must reach every tile); the one
  don't-care render now skips empty tiles but its cost is the shader.
- `render.new_render_scheduling` (Hyprland's triple buffering): 89% ->
  91% of frames on time, within noise.
- Hyprland's CPU load as such: 14% of the CPU; the issue was its time per
  frame sitting in front of the GPU's, not its total.

**Test traps:**

- `hypr-demo.sh jade` loads `/root/jade.lua` (setup-device.sh copies
  `hyprland-jade.lua` there); a config pushed under another name is
  silently not used.
- The demo's own loop toggles the floating window; benchmark with
  `hypr-bench.sh`, which starts Hyprland without the loop.
- Hyprland only blurs behind a client that asks for it (foot:
  `colors-dark.blur=yes`) and whose window opacity is below 1; otherwise a
  "blur" test measures no blur. A screen grab (`kms-grab`) settles it.
- Each `hyprctl` call spawns processes on a two-core CPU: one move per
  0.25 s costs about one late frame per call when the budget is tight.
  Use `glide` with a slow `windowsMove` animation to separate that.
- `G9P_SYNC=1` changes timing (and once hid a race); never judge speed or
  races with it on.
- Reloading the GPU module (rmmod/insmod) after Hyprland ran rebooted the
  iPad once. Prefer a fresh boot for kernel changes.

## Workflow

- Build only through orchard: `orchard build tools/a10 --device
  j71b`; boot a RAM payload with `orchard run tools/a10 --yes`
  (iPad in DFU), then `orchard exec -- modprobe powervr exp_hw_support=1`
  and `mesa/setup-device.sh MESA_DIR` (Zink, test programs, configs; /run
  is RAM, so after every boot).
- Kernel patches are edited in a small git repository built by
  `tools/patch-repo.sh init`, then written back with `export`; the shared
  kernel tree refuses hand edits.
- Mesa: `mesa/push-vk-zink.sh MESA_DIR` rebuilds and pushes the Vulkan
  driver (`deploy-zink.sh` only installs).
- Bound every command that waits: `timeout -k 5 N` on the device, an alarm
  on the Mac. A hung GPU job otherwise hangs the session.
