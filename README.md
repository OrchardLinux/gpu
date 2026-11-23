# Orchard GPU work

Linux GPU support for Apple's A-series chips (A7-A11), whose GPUs are
PowerVR Rogue derivatives run by Apple's own firmware, with Apple's own
shader ISA. This repository holds the research behind it: notes, the
bring-up guide, and the payloads and tools used on the devices. The
drivers themselves live upstream of here, in
[orchard](https://github.com/OrchardLinux/orchard) (kernel, bootloader)
and [OrchardLinux/mesa](https://github.com/OrchardLinux/mesa) (Vulkan).

| Chip | Devices | State | Notes |
|---|---|---|---|
| A10 (T8010) | iPad 6 (J71b) | Hyprland with all effects at 60 fps (Zink on the G9P Vulkan driver) | [a10/](a10/README.md) |
| A9 (S8000/S8003) | iPad 5 (J71s/J71t/J72s/J72t) | labwc desktop and Firefox with hardware WebRender on the GPU; merged in orchard as a powervr backend ([orchard#138](https://github.com/OrchardLinux/orchard/pull/138)) and [OrchardLinux/mesa#8](https://github.com/OrchardLinux/mesa/pull/8); see orchard's [docs/bring-up/gpu/a9-g5p.md](https://github.com/OrchardLinux/orchard/blob/main/docs/bring-up/gpu/a9-g5p.md) | [a9/](a9/README.md) |
| A8 (T7000) | iPod touch 6 (N102), iPhone 6 (N61); iPad mini 4 (J96) | iPod touch 6: GPU desktop (labwc and Qt through Zink on the Vulkan driver), display-DART scanout; iPhone 6: tester kit 4 passes (Vulkan, ladder 51/52, display); vertex textures and a Wayland stop still open ([orchard#196](https://github.com/OrchardLinux/orchard/pull/196), [OrchardLinux/mesa#18](https://github.com/OrchardLinux/mesa/pull/18), open). iPad mini 4: earlier bring-up in a8/, tester kit run pending | [a8/n102/](a8/n102/README.md), [a8/](a8/README.md) |
| A8X (T7001) | iPad Air 2 (J81) | Power-up reached; identity words read on Linux once the PMGR `dwi` domain is on (kept on by `apple,always-on`); the firmware core is a META MTP219, idle and readable through its slave port; no firmware loaded yet | [a8x/](a8x/README.md) |

More chips join as their own directories.

## Layout

- `<chip>/`: the notes and bring-up guide of one chip.
- `tools/<chip>/`: an [orchard](https://github.com/OrchardLinux/orchard)
  RAM payload for that chip's devices plus the tools used with it. Build
  and boot one with `orchard build tools/a10 --device j71b` and
  `orchard run tools/a10`; its README says what else it needs.

## Apple data

Nothing of Apple's is committed: no firmware, kernelcaches, device-tree
dumps, captures or compiled Apple shaders. The tools extract or capture
them locally from your own copies (for example
`tools/a10/tools/extract-firmware.sh`), and they stay gitignored.

## How it was made

The notes, tools and drivers were written with AI assistance (Claude), as
the commit trailers say, and checked on hardware. The Mesa fork is not
proposed upstream.

## License

GPL-2.0-or-later (LICENSE), as orchard; files with their own SPDX
identifier keep it.
