# GPU bring-up guide: Apple A10 (T8010) first, A9 and later next

The A10 GPU runs Hyprland with live blur at 60 fps under Linux. This guide
says what that took, in topic order, so it can be reproduced on the A9
(S8000/S8003) and on related Apple SoCs, and so the A10 and A9 work can be
merged into one driver. The lab notebooks one level up, in `a10/` (FENDER.md,
COMPUTE.md, RENDER.md, MESA.md, ISA.md, DRIVER.md) hold the evidence in the
order it was found; read them for detail, not for the current state.

Nobody needs to know Apple hardware beforehand: each part starts with the
concepts (coprocessors, the mailbox, RTKit, Fender, init data, tile-based
rendering, PDS and USC programs, ...) before it uses them.

| Part | Covers |
|---|---|
| [kernel.md](kernel.md) | coprocessor (IOP), mailbox, RTKit, the GFX firmware and its endpoints, Fender and the Rogue core, the firmware window and heap, init data layout, the boot sequence, job submission and its ordering rules, races found and how |
| [power-display.md](power-display.md) | GPU, memory and CPU clocks (performance states), the firmware's own DVFS, the display pipe and frame pacing |
| [mesa.md](mesa.md) | the Vulkan driver (G9P): Apple's shader ISA and our compiler, command streams, tile skipping, background objects, blending, the upstream code G9P bypasses, debug knobs, Zink and Hyprland |
| [performance.md](performance.md) | how to find where a frame's time goes, what the A10 measurements showed, what was ruled out, test traps, the workflow |
| [notebook-errata.md](notebook-errata.md) | where the notebooks disagree with the code |
| [tools/a10/tools/device](../../tools/a10/tools/device/README.md) | device-side tools: performance states, physical memory, the live Apple device tree, perf, the kernel job timeline |

Every fact uses the same layout: **what** is true, the **evidence** (a
firmware or kext address, an iOS capture or a measurement), the **code**
(file and function), how to **verify** it on new hardware, and an **A9**
line: likely the same, likely different, or unknown and what to check.
Most A9 lines say "unknown": nobody has looked at the A9 GPU firmware with
this method yet.

Apple data stays out of the repository: no firmware, no compiled Apple
shaders, no per-chip tables (frequencies, voltages, device tree dumps).
Read them on the device or from your own IPSW.

## A9 alignment checklist

What to establish on the A9 before sharing code with the A10 driver, in
the order the bring-up needs it. Each item points at the part that
explains it.

1. **Coprocessor and mailbox** (kernel.md 1.1-1.2): the GPU coprocessor
   node's `iop-version`, its register windows, the mailbox base (IOP +
   0x4000 on T8010) and its four interrupts. The A7 IOP mailbox variant
   should carry over (the A9's SmartIO uses the same block).
2. **RTKit handshake** (kernel.md 1.3): HELLO version and the endpoint map
   (T8010: protocol 12, endpoints 0, 1, 0x20, 0x21).
3. **Fender** (kernel.md 1.5, power-display.md): its base, the power-state
   register and how many performance states the `sgx` node lists. Never
   touch RGX registers before Fender reports the core powered.
4. **Init data** (kernel.md 3): the layout is the firmware build's, not the
   chip's. Re-derive it from the matching iOS kext (and an iOS capture if
   possible); do not copy T8010 offsets.
5. **Clocks** (power-display.md): GPU performance state, the memory/SoC
   performance state in PMGR (the A9 PMGR kext's `setPerfState`, if an unstripped one exists),
   CPU frequency. Measure bandwidth and ALU throughput before tuning.
6. **Job ordering** (kernel.md 4.3, 5): the free-list registration race and
   the fragment-done event are firmware behaviour; check whether the A9
   firmware needs the same waits before removing them.
7. **Shader ISA** (mesa.md 1.8-1.9, 2): whether the A9 shader core runs
   Apple's ISA (as the A10's does) or Rogue's; the Metal-toolchain probe
   in mesa.md settles it.
8. **Mesa side** (mesa.md 4): the shared-code bypasses (no SPM or load-op
   programs per render, clears as background objects) apply unchanged;
   without them every render compiles shaders on the CPU.
9. **Display** (power-display.md): ADBE was written for the A9's pipe;
   frame pacing and direct scanout should already work.
10. **Measure** (performance.md): `mesa/hypr-bench.sh` and the kernel
    timeline give comparable numbers on both chips.
