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

More chips join as their own directories. The A9 (iPad 5) work is
separate for now.

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
