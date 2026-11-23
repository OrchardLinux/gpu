# A8 (T7000) GPU on the iPod touch 6 (N102)

The A8's GPU (PowerVR GX6450 class, BVNC 3.10.4.5) runs a GPU desktop under Linux on the iPod touch 6, and the
same driver passes the tester kit on an iPhone 6 (N61). The kernel side is the A9's (G5P) Apple variant of the
upstream powervr driver with an A8 chip variant; the user side is the A9's Mesa Vulkan driver with A8 encodings,
with OpenGL ES through Zink. This directory is a clean write-up of the work from 19 to 23 November 2026, in topic
order. It sits next to the iPad mini 4 (J96) notes in [../](../README.md), which are the same chip on a
different board.

## Status (23 November 2026)

**Works [HW]:**

- **Kernel:** the powervr A8 variant probes, powers the GPU up in Apple's order, boots Apple's GPU firmware and
  runs compute and TA/3D render jobs. Soak: 514 000 jobs with no fault.
- **Vulkan 1.2** through Mesa's powervr driver ("PowerVR Apple A8"). The Vulkan ladder passes 51 of 52 rungs,
  every pixel checked on the CPU; `depth16` fails by design (the A8 has no D16).
- **OpenGL ES 3.1** through Zink (126 extensions). GL processes no longer load LLVM.
- **Desktop:** labwc composites on the GPU (wlroots' GLES2 renderer through Zink); the Quickshell desktop shell,
  its control centre and Qt apps draw through Zink with no refused shader; Qt Quick effects (shadow, blur, mask,
  colorize) work. With the display series, labwc's GPU buffers are scanned out directly through the display DART.
  This runs on an installed Omarchy system on the iPod.
- **iPhone 6 (N61), tester kit 4, a tester's device** ([reported on orchard#196](https://github.com/OrchardLinux/orchard/pull/196#issuecomment-7096670158)):
  probe, Vulkan smoke (compute 32/32, triangle exact), ladder 51/52 and display 9/9 over MIPI DSI all pass.

**Not yet [HW]:** vertex-stage textures, which Firefox's WebRender vertex programs need (fragment programs
compile); R8 load and cube arithmetic; MSAA, sRGB targets, three or more colour targets; partial render. A stop
of the device under Wayland vkmark on the latest kernel is **under investigation**. Details:
[OPEN-PROBLEMS.md](OPEN-PROBLEMS.md).

## Numbers

All on the iPod touch 6 under Linux **[HW]** unless noted. They moved between builds by a few per cent; the
range is given where builds differ.

| Benchmark | Result | Build and conditions |
|---|---|---|
| vkmark 256x256 (headless) | 842; **910** with `a8_joint=1` (TA and 3D queued together) | orchard#196 kernel |
| vkmark 256x256 | 800 (iPod), **840** (iPhone 6, tester-reported) | tester kit 3 / kit 4 |
| vkmark 750x1334 | 332 | orchard#196, mesa#18 |
| vkmark 640x1136, vertex scene, next to labwc | 551 fps, no faults | the PM-id-per-VM kernel |
| vkmark `clear` 750x1334 | 78 → 368 fps | once clears became GPU renders instead of a CPU fill |
| glmark2 (GLES through Zink) | 611 at 256x256, 311 at 750x1334 | the scenes the A8 did not refuse at the time |
| First triangle | TA ≈ 350 µs, 3D ≈ 350 µs | 64x64, first working build |

Where the time goes: each render is a serial TA job and 3D job with a fixed cost of roughly 0.85-1.7 ms
(glmark2's desktop blur is 11 renders per frame), the firmware self-parks between jobs (about +435 µs per job that
wakes it), and the GPU stays at its lowest performance state (365 MHz). Per-job kernel and firmware cost is the
next target.

## Chapters

| File | About |
|---|---|
| [BRINGUP.md](BRINGUP.md) | PMGR and the GPU PLL (MiscACG, SOC_TVM), the power-up order, bridges, firmware boot, rings and doorbell, compute, the first triangle, the parameter manager, PM id per VM, A8 vs A9 |
| [SHADERS.md](SHADERS.md) | A8 vs A9 encodings: PDS, compute, integer subtract, end of tile, varyings, the sample instruction, texture state and the multi-image layout, cube maps, `texelFetch`, vertex sampling |
| [MEMORY.md](MEMORY.md) | PBE words, ZLS tile rounding, colour tile padding, region headers, Qt without depth/stencil, GL without LLVM |
| [DISPLAY.md](DISPLAY.md) | adbe on the T7000, display-DART scanout and its self-check, MIPI vs eDP, the iPhone 6 result |
| [POWER.md](POWER.md) | GPU idle (self-park and host power-off) and the D2186 USB charge grant |
| [OPEN-PROBLEMS.md](OPEN-PROBLEMS.md) | the Wayland stop under investigation, vertex textures, R8 load and cube arithmetic, what is still refused |
| [A8X.md](A8X.md) | what carries over to the A8X (T7001, iPad Air 2) and what differs |

## Evidence levels

Every claim carries one:

- **[HW]** measured on the device under Linux;
- **[iOS]** measured or captured under iOS 12.4 on the device, with our own Metal test program or by reading the
  kernel's records;
- **[KC]** read in the iOS 12.4 (16G77) kernelcache, the GPU firmware image or Apple's Metal and compiler
  libraries; Apple functions are cited by unslid address;
- **[INF]** inferred, not proven.

## Where the code lives

All open, not merged yet:

- [orchard#196](https://github.com/OrchardLinux/orchard/pull/196): the kernel side. The S8003 chip variant table,
  per-chip GPU ID and heaps, the `apple,t7000-gpu` binding, the A8 firmware boot and power sequence, compute and
  render jobs with the PM pool (`a8_pm_blocks`, `a8_pm_grow`), fault and hang reports, IRQ-thread completion and
  Apple's doorbell, the optional joint TA/3D queue (`a8_joint`), the `apple_jobs` debugfs statistics; the T7000
  device tree; and the `examples/ipod-gpu-drm` RAM test payload.
- [orchard#203](https://github.com/OrchardLinux/orchard/pull/203): the firmware recipes. Two steps extract the META
  LDR image and the 2 KiB border-colour table from the iPod touch 6 iOS 12.4 kernelcache in Apple's public IPSW,
  on the user's machine, and check them against pinned hashes (`apple/gfx-t7000.bin`, `apple/gfx-t7000-border.bin`).
  No Apple bytes are in the repository.
- [orchard#204](https://github.com/OrchardLinux/orchard/pull/204): the display pipe ([DISPLAY.md](DISPLAY.md)).
- [orchard#202](https://github.com/OrchardLinux/orchard/pull/202): N102 battery status from the D2186; the charge
  grant in [POWER.md](POWER.md) builds on it.
- [OrchardLinux/mesa#18](https://github.com/OrchardLinux/mesa/pull/18): the Vulkan driver. A8 device info
  (`has_apple_g4p`), the A8 forms in the G5P encoders (sample, iterators, emit, cube, integer subtract, vertex
  sample), the A8 clear and end-of-tile programs, the image layout rules, the mirrored region-header ring, and
  Zink and blitter changes. Some later fixes (the shared dma-buf mapping) are not in it yet.

The A9 notes this builds on are in [../../a9/](../../a9/README.md).

## Testing with the kit

[A8 GPU tester kit 4](https://github.com/brkosebay/hardware/releases/tag/a8-gpu-tester-kit-4) is the orchard#196
test payload, prebuilt with the #204 display series: kernel, m1n1, PongoOS, static tools, the `a8-gpu-drm` test
program and a Vulkan bundle with vkmark. It is Vulkan only (no GL). It boots from RAM (checkm8 → PongoOS → m1n1 →
Linux), writes nothing to the device, and a reboot returns to iOS. It ships no Apple files: `setup.sh` fetches the
GPU firmware from Apple's public iPod touch 6 IPSW.

1. On a Mac or Linux PC: `./setup.sh BOARD`.
2. Put the device in DFU, then `./run.sh BOARD`. (On a Linux host the boot step can fail with `EACCES` when the
   device re-enumerates before udev applies its permissions; run that step as root.)
3. On the USB serial root shell, in order, each under a 30 s hardware watchdog: `a8-gpu-drm-test probe`,
   `a8-gpu-drm-test vk`, the ladder rungs, then `a8-gpu-drm-test display`. Optionally `/opt/a8vk/vkmark.sh --size
   256x256`. On the iPad mini 4 run `display` first.
4. Report on orchard#196: the board, the probe output, the RESULT lines, the display output and what the screen
   showed.

Boards: N102 (iPod touch 6) tested; N61 (iPhone 6) passed with kit 4; J96/J97 (iPad mini 4, eDP) and N56 (iPhone
6 Plus) are not yet tested. The ladder and the iOS capture program are in [../../tools/a8/](../../tools/a8/):
[ladder/](../../tools/a8/ladder/README.md) and [passcap/](../../tools/a8/passcap/README.md).

## Apple data

Nothing of Apple's is here: no firmware, kernelcache, device-tree dump, capture, compiled shader, disassembly or
decompiler listing. Encodings are described as field positions and meanings in our own words, and register values
were read from our devices or derived from Apple's code as described. Board-specific facts are given for the board
model, not for a particular unit; fused per-device values (voltages, calibration) are left out.

Written with AI assistance (Claude) and checked on hardware where the tags say **[HW]**.
