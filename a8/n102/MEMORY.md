# A8 memory: render targets, tile rounding and RAM

The iPod touch 6 has about 1 GB of RAM, so how the driver lays out images matters as much as whether they are
correct. Tags as in [README.md](README.md#evidence-levels).

## Colour targets (PBE)

- **[KC][iOS]** The A8 uses Imagination's own split, as upstream Rogue does: two register qwords per target, which
  are Rogue's `PBESTATE_REG_WORD0` and `REG_WORD1` bit for bit (no third word), plus four end-of-tile dwords per
  target ([SHADERS.md](SHADERS.md#fragment-output-and-end-of-tile)). The A9 puts everything into seven end-of-tile
  dwords instead.
- **[KC]** Word 0: bit 0 y-flip; bits 4/5 gamma (sRGB) and two-component gamma; 6-19 minimum clip x (always 0);
  20-31 four 3-bit channel swizzles; 32-33 memory layout (0 linear, 1 twiddled 2D); 34-49 line stride (linear only,
  (stride in pixels − 1) >> 1); 50-51 rotation; 52-55 log2 depth; 56 downscale (resolve); 57 tile-relative (always 1);
  58 dither. Word 1: 0-13 maximum clip y (height − 1); 14-27 z slice; 28-31 log2 height (twiddled only); 32-45
  maximum clip x (width − 1); 46-59 minimum clip y; 60-63 log2 width (twiddled only). Sizes are of the mip level.
- **[KC]** Unused targets are an empty rectangle (minimum clip (1,1), maximum (0,0)), not zero. There is no sample
  count in these words.
- **[KC]** The 3D record carries the pair in two sets: set A at `W+0x118` and again at `W+0x4c0` (the resolve pair if
  resolving, an empty pair if the store discards, else the main pair) and set B at `W+0x540` (always the main pair,
  probably for partial renders **[INF]**). Write both. The A9's writes at `W+0x108..+0x130` land inside the A8's PBE
  block and must not be carried over.
- **[iOS]** The memory layout field must match the layout the driver allocated, or the image comes out
  Morton-scrambled. The captured control value "2" in the end-of-tile words means 8-bit UNORM, target 0: it is not
  a layout flag.

## Depth and stencil (ZLS)

- **[HW]** The A8 driver builds D32F and D32F_S8 only; Zink renders `DEPTH_COMPONENT16` as D32F. **[KC]** There is
  no D16 path to copy: Metal's `Depth16Unorm` arrived in iOS 13 and the iPod runs iOS 12.4. The Vulkan ladder's
  `depth16` rung therefore fails by design.
- **[iOS]** The A8's ZLS control word is the A9 form plus Rogue's ZLS extent fields (in 32-pixel tiles, minus one);
  there is no separate pixel-size word.
- **[HW]** **Tile rounding:** in twiddled mode the extent must be the tile count **rounded up to a power of two** on
  each side (Rogue's documented rule). The plain count broke every depth/stencil reload at sizes whose tile count is
  not a power of two, the full 640x1136 screen included; Apple's only capture was 64x64, where both readings agree.
  Fixed; every size from 640x1136 down to 37x29 reads back right.
- **[HW]** Depth/stencil planes are now rectangular: each side 32-aligned and padded to its own power of two, in
  rectangular Morton order. Guard bytes past the planes stayed intact in 112 cases. A 640x1136 D32F_S8 buffer went
  from 20 to 10 MiB; 528x80 from 5 MiB to 640 KiB.

## Colour tile padding

- **[KC][HW]** Single-level colour images are twiddled on the A8 (Apple's rule, and what makes loading Zink's
  one-level targets work). Images with external memory handles stay linear.
- **[HW]** Twiddled non-power-of-two images pad to power-of-two squares: a 750x1334 target became 1024x2048, 8 MB
  instead of 4. Before the fix one Qt shell process held 57 images in 146 MB, 70 MB of it padding.
- **[HW]** Fix: single-level images whose sides are not both powers of two stay linear (2018x1136 BGRA8 16 → 8.8
  MiB). Power-of-two images stay twiddled. Both render, reload and sample right.
- **[HW]** Cost: point-sampling an 800x600 one-level texture minified (vkmark's effect2d) fetches about 1.9 MB of
  64-byte lines per frame twiddled against 0.8 MB linear (+0.5 ms). Linear filtering is equal or better twiddled,
  and the padding itself costs nothing (the texture unit never addresses it). Metal twiddles the same texture, so
  this is the access pattern, not a driver bug; twiddled stays the default for textures.
- **[iOS]** Linear colour images still need **whole 32-row tiles**: Apple sizes a one-level 800x600 texture to 608
  rows. A 640x1136 image is 35.5 tiles tall, and storing the last tile row writes rows 1136-1151, past a tightly sized
  buffer; that was one GPU write fault just past a buffer **[HW]**. Mesa pads linear single-level colour images to
  32-row tiles; images created by the window system without modifiers may still skip the pad **[INF]**.

## Region headers and tail pointers

- **[KC]** Each command queue owns a render-target object. The kext writes no initial contents into the region
  headers or tail-pointer buffers; zero-filled pages are the valid start state. Region headers form a ring: one buffer
  mapped twice (VA and VA + R), each frame taking the next slice, a slice reused after 16 frames without clearing.
- **[KC]** Sizes (from `0xfffffff00847c000`, not checked on the device): tx = ceil(w / 32), ty = ceil(h / 32);
  sample-count factors (1,1), (2,2) and (2,4) for 1, 4 and 8 samples; X = 4·sx·roundup4((tx + 3) >> 2), Y likewise;
  region headers 5·X·Y bytes; tail pointers 8·P² with P = max(X, Y) rounded up to a power of two.

## Qt without depth and stencil

- **[HW][INF]** QtWayland emulates a blocking swap with `glFlush` before `eglSwapBuffers` when EGL offers swap
  interval 0. That flush ends Zink's render pass before the swap's depth invalidate arrives, so every Qt window
  stored its depth buffer every frame. Not an A8 bug.
- **[HW]** The session default is now `QSG_NO_DEPTH_BUFFER=1 QSG_NO_STENCIL_BUFFER=1`: the Qt shell went from 140
  to 88 MB and system shared memory from 211 to 145 MB. The cost is more overdraw and the loss of non-rectangular
  stencil clips **[INF]**. Memoryless depth (Vulkan transient, lazily allocated attachments, as Metal's memoryless
  storage mode) is specified but not built.

## GL without LLVM

- **[HW]** Mesa's GL library used to link libLLVM because llvmpipe was built in, so every GL process mapped it
  (about 19 MB per Qt process). GL is now built with LLVM disabled and only Zink and softpipe as Gallium drivers;
  the packaging fails if the GL library needs libLLVM. Software GL is still there as softpipe.
- **[HW]** Caution: a GL run without `MESA_LOADER_DRIVER_OVERRIDE=zink` can fall back to softpipe silently and
  "pass". That invalidated some early vertex-texture results ([OPEN-PROBLEMS.md](OPEN-PROBLEMS.md#vertex-textures)).

## The parameter buffer and other driver memory

- **[KC]** Apple's A8 parameter buffer goes up to 96 MiB (the A8X's to 144 MiB). Our kernel gives each VM a fixed
  pool (default 32 blocks of 128 KiB; one PM set is about 6.4 MiB per VM) and cannot grow it or partial-render, so a
  parameter-memory overflow hangs the TA: a mesh rung hung at 16k triangles at 256x256 before the pool work **[HW]**.
  Sizing the pool by render area (8 blocks at 640x1136, Apple's steady A8 state) is specified, not built **[iOS][INF]**.
- **[HW]** The physical-device winsys is query-only on the A8, so each process has one GPU VM instead of two.
- **[INF]** Ported from the A9 Mesa: a byte cap on the render-target dataset cache (8 MiB on the A8), command
  uploads in their own suballocators, purgeable idle suballocator chunks and an eviction-aware submit (both off until
  the A8 kernel reports eviction support), and per-size depth/stencil load/store counters in the buffer log.
