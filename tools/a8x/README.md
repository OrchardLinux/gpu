# A8X (J81) firmware-image tools

Offline tools for the iPad Air 2 META firmware boot described in
[`a8x/FIRMWARE-BOOT.md`](../../a8x/FIRMWARE-BOOT.md). They need no device and
no third-party Python packages, and they contain no Apple data: they read the
firmware image from **your own copy** of the iPadOS 15.8.5 (19H394) kernelcache
(the `__TEXT.__const` section of `com.apple.AGXFirmwareKextG4G`, 117,684 bytes,
sha256 `55018c7eacef950f…`), and what they write stays in directories you name
(keep them outside git or gitignored).

- `j81_meta_ldr_layout.py`: parses the META LDR stream and rebuilds the
  "firmware image" buffer and the boot list the iPadOS driver builds, plus the
  31-word Fender ConfigRAM list. Every rule cites the 19H394 instruction that
  implements it. `python3 -I tools/a8x/j81_meta_ldr_layout.py <ldr> --tables T --private P [--pc-phys N]`.
- `test_j81_meta_ldr_layout.py`: unit tests; the synthetic ones always run,
  the real-image ones run when `J81_LDR_19H394` (and optionally `J81_LDR_81`)
  name your images.
- `j81_f3a_build.py`: builds the position-independent 1 MiB blob the J81 GPU
  module copies into its DMA region (heap image at GPU VA `0xe1c0000000`, header,
  ConfigRAM template). `python3 tools/a8x/j81_f3a_build.py <ldr> <new private dir> [cfg+0x2f0] [windows=1]`.
  Fields marked GUESS in its docstring are not decoded from the kext.

The kernel module and the runner that boot the firmware are in
[mattonik/ipad-nixos](https://github.com/mattonik/ipad-nixos) (`kernel/j81-gpu/`,
`boot/`); the module replays a table of 66 GFX bridge settings that lives
there (`kernel/j81-gpu/gfx-bridge-plan.h`) and is not part of this repository.
