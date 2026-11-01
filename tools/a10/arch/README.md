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
orchard pull /run/arch/tmp/shot.png shot.png
```

Each run prints Labwc's and the shell's CPU time, on the GPU the
intervals between Labwc's renders, and the first errors of Labwc and the
shell; `/run/arch/tmp/` keeps the logs and the screenshot.

The root is slim (no Firefox, Dolphin or services) and the shell runs as
root without Omarchy A's session (greetd, systemd user services), so menus
that need those may fail; what is measured is rendering.
