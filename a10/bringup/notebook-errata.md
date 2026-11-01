# Where the lab notebooks disagree with the code

The notebooks (FENDER.md, COMPUTE.md, RENDER.md, MESA.md, ISA.md, DRIVER.md) are chronological: later entries correct earlier ones. These are the places found while writing the guide where a note and the code disagree. The code is right unless stated otherwise.

## Kernel side

- MESA.md's blur-cache paragraph said a fragment fence waiting for the
  fragment-done event "changed nothing and was dropped". It did not fix
  that race, but commit 40bae56 added it later for the display, and
  `pvr_apple_poll_work()` waits for it. Corrected in MESA.md.
- DRIVER.md gives code heap bases 0xDA00000000/0xE000000000. The code uses
  0x2a00000000/0x2c00000000 (38-bit limit, `pvr_apple.h`).
- FENDER.md §12 put the ring descriptors at X+0x8 with two pointers. §19.2
  and the code use X+0xc with three index pointers plus entries.
- FENDER.md §13 lists X+0x1ec/+0x1fc as pointers. COMPUTE.md and the code
  treat them as values (0).
- The free-list unregister address: the code comment says fw 0x13144,
  RENDER.md says fw 0x130a6 for the retirement. Both may lie in the same
  routine; unverified.
- `pvr_apple_layout.c` describes `FW_VA_HEAP2` as "inner non-cacheable",
  but both descriptors use flags 0, so both are inner non-cacheable.

## Mesa side

- `pvr_arch_g9p_gfx.c` header comment says blending, load ops other than
  clear, textures and uniform buffers aren't done. All four are implemented
  below it, so the comment is stale. The `g9p_compile.c` header still says
  "compiler for compute shaders" but covers all three stages.
- `G9P_DUMP_FULL`: commit `9c5258a2aae` and MESA.md ("`G9P_DEBUG=1
  G9P_DUMP_FULL=1`") say it works with `G9P_DEBUG`. In code the buffer dump
  is gated on `G9P_DUMP` (`dumping()` in `buffer_addrs`), so it needs
  `G9P_DUMP=1`.
- MESA.md "Hyprland renders" and the `73cb8c5669a` message give an 8 MiB
  free list. Code and `4ac3eedab44` give 32 MiB. MESA.md also calls
  `G9P_FREE_LIST_SIZE` as if tunable; it's a compile-time macro.
- Border shader size: 116 registers / 22 KB (`d1ab45daed3`, MESA.md "Window
  borders", test config) vs 123 registers / 30 KB (MESA.md "The effects
  demo"). Probably different Hyprland configs or compiler states; not
  reconciled.
- Render ordering: `8433037fe15` added Mesa-side ordering; `ba304d33f58`
  removed it (the kernel orders jobs, and the hang was a firmware
  free-list registration race fixed in the kernel). Code has no ordering;
  older MESA.md paragraphs still describe it.
- RENDER.md "Resized render" says ISP_CTL bit 17 doesn't make the ISP
  process empty tiles. "Render target captures" and the code say it does.
  The later note is right.
- `g9p_compile.h` puts fragment buffers from dword 16 and says only texture
  state at dword 0 samples correctly, while `upload_textures` would place a
  second texture at dword 16 (`G9P_TEX_STRIDE`). That's latent only: the
  compiler accepts one texture.
