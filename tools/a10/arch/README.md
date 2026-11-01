# Omarchy A on the A10 GPU: the RAM experiment

Omarchy A draws on the CPU today: Labwc on wlroots' pixman renderer, Qt
Quick in software, software GL. This experiment answers, before anything
changes in the product, whether its desktop runs on the GPU as it is:

1. Does Arch Linux ARM's own Mesa (EGL, GBM, Zink) run on the fork's Vulkan
   driver? So far only our own Zink build (Debian) has.
2. Does Labwc (wlroots' GLES2 renderer) run on it? So far only Hyprland has.
3. Does Omarchy A's shell (Quickshell, Qt Quick on OpenGL) render on it?
4. Does a rotated output work on the GPU path?

It boots the A10 payload, puts a slim Arch Linux ARM root into the iPad's
RAM with the packages Omarchy A draws with, adds the fork's Vulkan driver
built against Arch, and runs Labwc with Omarchy A's shell and a scrolling
foot, once on the GPU and once as the product does today.

## Steps

Once, on the Mac:

```sh
podman build -f tools/a10/arch/Containerfile.build -t orchard-gpu-alarm-build tools/a10/arch
podman build -f tools/a10/arch/Containerfile.runtime -t orchard-gpu-alarm-runtime tools/a10/arch
sh tools/a10/arch/build-root.sh                       # the root as a 330 MB squashfs
sh tools/a10/arch/build-vk.sh PATH/TO/OrchardLinux/mesa
sh tools/a10/mesa/build-gl-tests.sh tools/a10/out       # kms-grab, for screenshots
```

The root is 1.1 GB of files once the base image's kernel, firmware and
caches are gone, too much for a 2 GB iPad's RAM next to a desktop, so it
travels as a compressed squashfs (gzip, the one compressor the kernel's
squashfs reads) and is mounted read-only with a RAM overlay. The first
image build downloads about 2 GB of packages from omarchy-a's pinned
mirror; later builds reuse it.

Per boot (iPad in DFU):

```sh
orchard run tools/a10 --yes
orchard exec -- modprobe powervr exp_hw_support=1
sh tools/a10/arch/setup-device.sh PATH/TO/omarchy-a
orchard exec -- sh /run/start-labwc.sh gpu 15
orchard exec -- sh /run/start-labwc.sh cpu 15
orchard exec -- env ROT=90 sh /run/start-labwc.sh gpu 15
orchard pull /run/arch/tmp/shot.ppm shot.ppm
```

Each run prints Labwc's and the shell's CPU time, on the GPU the
intervals between Labwc's renders, and the first errors of Labwc and the
shell; `/run/arch/tmp/` keeps the logs and the screenshot (what the display
scans out, at half size).

The root is slim (no Firefox, Dolphin or services) and the shell runs as
root without Omarchy A's session (greetd, systemd user services), so menus
that need those may fail; what is measured is rendering.

## Results (2026-11-02, iPad 6)

All four questions: yes, with Mesa fork 4a8c71666d9 (packed vertex
formats, unbound attributes, texelFetch: what Qt Quick and Zink's blits
needed from the backend).

| | GPU (Zink) | CPU (pixman) |
|---|---|---|
| frames, 30 s with a scrolling foot | 1816 of 1817 intervals under 20 ms (16.7 ms mean) | not traced |
| Labwc CPU, 30 s | 322 ticks (11 % of a core) | 57 ticks (2 %) |
| rotated 90° | 1847 of 1848 under 20 ms | |

- Arch's own Mesa (EGL, GBM, Zink) runs on the fork's driver unchanged;
  vk-suite 8/8 in the Arch root.
- The GPU draws the whole screen every frame (load op, full area in the
  trace), pixman only what changed: Labwc's CPU time on the GPU path is
  Zink's per-frame work, about 1.8 ms a frame. Damage (buffer age) on the
  GPU path is the next thing to measure.
- Open: grim (screencopy maps a buffer the driver cannot map yet), depth
  and stencil textures (D24S8, which Qt asks for), Xwayland is not in the
  root.
