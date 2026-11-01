# Apple A10 (T8010) GPU

The iPad 6's GPU (J71b): a PowerVR Rogue core (CORE_ID 0x011b0602) run by
Apple's GFX firmware on an RTKit coprocessor, with Apple's own shader ISA.
Under Linux it runs Hyprland with every effect, live blur included, at
60 fps, through Zink and the Mesa fork's G9P Vulkan driver.

**Start with [the bring-up guide](bringup/README.md)**: what it took, in
topic order, each fact with its evidence, the code it lives in, how to
check it on new hardware, and what to check on the A9. The notebooks below
are the evidence, in the order things were found; later entries correct
earlier ones, and [bringup/notebook-errata.md](bringup/notebook-errata.md)
lists where they disagree with the code.

| Notebook | About |
|---|---|
| [FIRST-LOOK.md](FIRST-LOOK.md) | the first days: reaching the core, the coprocessor, early results |
| [FENDER.md](FENDER.md) | the kext and firmware side: Fender, the coprocessor's boot, init data, power and clocks |
| [COMPUTE.md](COMPUTE.md) | the first compute jobs, experiment by experiment, and Apple's PDS encodings |
| [RENDER.md](RENDER.md) | iPadOS render captures and how a render is put together |
| [ISA.md](ISA.md) | the shader ISA as decoded from Apple's compiler output |
| [PDS-OFFLINE.md](PDS-OFFLINE.md) | the PDS investigation done offline and its hardware follow-up (experiments 50-61) |
| [DRIVER.md](DRIVER.md) | the kernel driver's plan and milestones (powervr UAPI) |
| [MESA.md](MESA.md) | the Vulkan driver, Zink, Hyprland and the performance work |
| [REFERENCE.md](REFERENCE.md) | the A10 against existing driver stacks: what carries over and what does not |
| [PROVENANCE.md](PROVENANCE.md) | where every hardware-facing value in the driver comes from |

## Where the code is

- **Kernel and bootloader** in [orchard](https://github.com/OrchardLinux/orchard):
  the driver (`kernel/patches/drivers/gpu/0001`, an Apple variant of
  drm/imagination), its device tree (`kernel/patches/devices/t8010/0011`),
  the display pipe (ADBE, t8010/0010), the SoC and memory performance
  states (soc-apple/0011-0012, t8010/0012) and m1n1's GPU performance
  states (`boot/m1n1/patches/orchard/0011`).
- **Vulkan driver** in [OrchardLinux/mesa](https://github.com/OrchardLinux/mesa)
  (`src/imagination`, the G9P backend).
- **Payload and tools** in [`tools/a10/`](../tools/a10/README.md). Paths
  in the notes like `mesa/…`, `tools/…` and `ios-capture/…` are relative to
  it. The work started as orchard's `examples/gpu-001`, the name older
  entries use.
