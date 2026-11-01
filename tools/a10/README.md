# A10 GPU payload

An orchard RAM payload for the iPad 6 (J71b, Apple A10/T8010) with the
tools the A10 GPU work uses: boot it, load the GPU driver, put Mesa and
Hyprland on it, and measure. The notes and the bring-up guide are in
[`a10/`](../../a10/README.md).

Needs `orchard` on PATH (it builds the kernel, whose GPU driver is in
orchard's `kernel/` layers), Podman, and the GPU firmware (below). Paths in
this directory's scripts and in the notes (`mesa/…`, `tools/…`,
`ios-capture/…`) are relative to it.

## The firmware

The GPU firmware is Apple's and is not in this repository. Extract it from
your own iPadOS 17.7.11 kernelcache; the script checks it is the tested
image:

```sh
ipsw download ipsw --device iPad7,5 --build 21H461 --kernel
tools/extract-firmware.sh PATH/TO/kernelcache.release.iPad7,5_6
```

It lands in `rootfs/lib/firmware/apple/gfx-t8010.bin` (gitignored).

## Boot, driver, desktop

Once, on the Mac (the Podman images first, then the test programs into
`tools/a10/out`):

```sh
podman build -f tools/a10/mesa/Containerfile.sid -t orchard-mesa-g9p:sid tools/a10/mesa
podman build -f tools/a10/mesa/Containerfile.runtime-sid -t orchard-mesa-g9p-runtime:sid tools/a10/mesa
sh tools/a10/mesa/build-vk-test.sh tools/a10/out
sh tools/a10/mesa/build-gl-tests.sh tools/a10/out
python3 tools/a10/mesa/fsops.py tools/a10/out
```

Then per boot:

```sh
orchard run tools/a10 --yes                 # iPad in DFU; builds what is missing
orchard exec -- modprobe powervr exp_hw_support=1
sh tools/a10/mesa/setup-device.sh PATH/TO/OrchardLinux/mesa
orchard exec -- sh /run/hypr-demo.sh 120 jade   # Hyprland, Omarchy's Jade Horse look
```

`setup-device.sh` builds a Debian unstable chroot with Hyprland in the
iPad's RAM (`/run/sid`) and installs the Mesa fork's Zink build into it
(`mesa/deploy-zink.sh`; `mesa/push-vk-zink.sh` rebuilds and pushes only
the Vulkan driver). The Mesa fork needs a `build-zink` build made in the
`orchard-mesa-g9p:sid` image, once:

```sh
podman run --rm -v PATH/TO/mesa:/mesa localhost/orchard-mesa-g9p:sid sh -c '
    cd /mesa && meson setup build-zink --prefix=/usr --libdir=lib/aarch64-linux-gnu \
        --buildtype=debugoptimized -Dplatforms=wayland -Dvulkan-drivers=imagination \
        -Dgallium-drivers=zink -Dglx=disabled -Degl=enabled -Dgbm=enabled \
        -Dgles1=disabled -Dgles2=enabled -Dglvnd=enabled -Dllvm=enabled \
        -Dvideo-codecs= -Dtools= -Dvulkan-layers= && ninja -C build-zink'
```

`/run` is RAM: run `setup-device.sh` after every boot.

## What is here

| Path | What |
|---|---|
| `init`, `payload.toml`, `rootfs/` | the payload: USB serial and SSH, the GPU driver staged as a module |
| `mesa/` | Mesa and Hyprland on the device: setup, demo (`hypr-demo.sh`), frame-time benchmark (`hypr-bench.sh`), Vulkan tests (`vk-tri.c`, `vk-suite.sh`), screen grabs (`kms-grab.c`) |
| `arch/` | the Omarchy A GPU experiment: an Arch Linux ARM root in RAM with Labwc, Omarchy A's shell and Arch's Mesa on the fork's Vulkan driver ([README](arch/README.md)) |
| `tools/device/` | device-side tools: GPU and SoC/memory performance states, physical memory, the live Apple device tree, perf for the chroot, a kernel job timeline ([README](tools/device/README.md)) |
| `tools/extract-firmware.sh` | the firmware, from your kernelcache |
| `tools/patch-repo.sh` | edit the GPU driver's kernel patch layers in a small git repository (`ORCHARD=` an orchard checkout) |
| `tools/isa/` | the A10 shader ISA assembler and probes (`g9p.py`) |
| `tools/*.py` | decoders: firmware disassembly, kernelcache cross-references, control streams, captures |
| `tools/pvr-*.c` | powervr UAPI test programs (compute, render, triangle) |
| `tools/agx-init*.sh` | the numbered firmware-init experiments of FENDER.md and COMPUTE.md (historical) |
| `ios-capture/` | the iPadOS-side capture tool (ad-hoc signed; runs under palera1n) |
| `kernel/` | the first, out-of-tree bring-up modules and early driver patches (historical); `bringup-driver-with-selftests.patch` is the last driver patch with the self-tests and the parameter-manager trace, before they left the driver on orchard main |

Apple data stays out of git: firmware, kernelcaches, device-tree dumps,
captures and compiled Apple shaders are gitignored and only ever local.
