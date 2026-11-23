# A8 shader and state encodings: what differs from the A9

The A8's Mesa support runs on the A9 (G5P) code paths, with a device bit (`has_apple_g4p`) that selects an A8
form wherever the two differ. This chapter lists those differences, as field positions and meanings in our
own words. Tags as in [README.md](README.md#evidence-levels); **[iOS]** here means Apple's encoding seen in a
capture of our own Metal test program on the iPod (the [passcap](../../tools/a8/passcap/README.md) tool), not
copied output.

## The compiler family

- **[KC]** iOS 12.4's shader compiler has one backend (`agx1`) for the A8 (g4p), A8X (g4g), A9 (g5p) and A10
  (g9p). The A8 is the base instruction set; the later chips add "G5" and "G9" instruction features. The A7
  has a separate backend. Lowering differences named in the compiler: gamma operations (G5 only) and atomics.
- **[KC][iOS]** So the A8 is in the A10 encoding family, not stock Rogue: padding and end words of compute
  kernels fall on 64-byte boundaries and the empty kernel is identical to the A10's. Imagination's upstream
  Rogue compiler is not a usable base; the A9 encoders are.
- **[HW]** The A8 has **one** code execution base, GPU VA `0x3_00000000` (the PDS heap); USC offsets count from
  it. The A9 has separate PDS and USC bases.

## PDS

- **[iOS][KC]** The A8's PDS DOUT words use Rogue's plain field layout (src1 in bits 23:16, src0 in 14:8). The A9
  and A10 use Apple's extended three-source layout (24:18, 17:10, 9:3). Every PDS builder now takes the device's
  features; the extended form is off on the A8.
- **[iOS]** The compute launch PDS program is 5 words on the A8 (the A9's is 8, with padding halts). The end-of-
  tile PDS info word for one target is `0x202` on the A8 (`0x402` on the A9).
- **[iOS]** PDS common-store size: Apple's A8 rule is ceil(dwords / 16); the A9 rule we started from,
  max(4, 2 × ceil(dwords / 16)), over-allocates but works.

## Compute

- **[HW][iOS]** Memory load and store have an A8-only form: the size in the first word, data and address
  registers in the second and third, a store marked by bit 15 of the third word and bit 14 of the fourth. The
  A9's form completes on the A8 but stores nothing.
- **[HW]** A 64-bit buffer address is built from 32-bit adds plus a carry operation that leaves the carry in the
  high half; the A9's 64-bit add faulted on the A8. The first port added the wrong half of the carry, which put
  stores at `0x11_xxxxxxxx` for bases with bits 16-23 set. Graphics-stage 64-bit address adds (indexed UBO, SSBO,
  transform feedback) are refused on the A8 until that build is ported to them **[INF]**.
- **[HW]** No fence bit on A8 compute kernel records (setting one locks the GPU up). A pass ends with Apple's empty
  USC task plus a fenced DOUTC task; the A9's tail locked the A8 up.
- **[KC]** From Apple's A8 Metal driver: residency follows the A9's formula with different constants, capped at
  512 and a multiple of 32; execution width 32; 512 threads per threadgroup; 16 KiB threadgroup memory;
  60 interpolated components; sample counts 1, 2 and 4; 8192-texel 1D/2D/cube textures, 2048 for 3D and array
  layers. "One workgroup per task" is keyed on device atomics, not on barriers.
- **[KC]** Apple's A8 driver has no indirect draws, no indirect dispatch and no base vertex or base instance; Mesa
  refuses the indirect forms by name on the A8.

## Integer subtract

- **[HW]** The A9's register subtract returns **x** for x − y in A8 fragment programs. It showed up as
  `ivec2(gl_FragCoord) % 3` reading back x itself while 3q and the quotient alone were right.
- **[HW]** Fix: in A8 fragment programs, x − y becomes x + y × (−1) and −x becomes x × (−1) (integer multiply and
  add work; −1 comes from a move-immediate). Remainders are rebuilt as a − (a / b) × b, and constant-divisor
  division goes through the float reciprocal with two integer corrections. Vertex programs keep their forms.
  Integer modulo, division, multiply by 3 and `texelFetchOffset` now read every pixel right; the last one had
  broken WebRender's desktop-GL addressing.

## Fragment output and end of tile

- **[iOS]** `emitpix` differs: the A8 sets byte 3 bit 0 and adds a 16-bit extension; the output word count (1, 2
  or 4) is in the high nibble of byte 1.
- **[iOS]** End-of-tile data is **4 dwords per target** on the A8: address low, address high, a format word, 0.
  The format word is (PBE packmode << 16) | conversion, with conversion 2 = UNORM, 0 = float or raw, 8 = integer.
  Format, size and stride live in the 3D record's PBE words ([MEMORY.md](MEMORY.md#colour-targets-pbe)). The A9
  sends the full PBE state, 7 dwords per target.
- **[iOS][HW]** R8, RG8, R32F and RGBA8UI emit one output word (R8 and RG8 as an f16 pair in one register, R32F as
  one f32, RGBA8UI as bytes packed R | G << 8 | B << 16 | A << 24). RGBA16F and RGB10A2 share the BGRA8 programs;
  only the format word differs.
- **[iOS]** With two colour targets the fragment program writes the last target's words first, and clear colours
  are uploaded in reverse target order. Only RGBA8/BGRA8 pairs are admitted for now.
- **[iOS]** 4x MSAA needs no per-sample end-of-tile program on the A8 (the 1x one is reused), unlike the A9. Not
  built: the 4x TA state program has not been captured.

## Varyings (iterators)

- **[iOS]** The A8 iterator is a different instruction family from the A9's (the first byte differs). Component
  count and slot are in the instruction; f32 vs f16 is selected by a trailing extension. Perspective vs
  no-perspective is a value in byte 3; centroid is an extension bit.
- **[iOS][HW]** f32 iterators are seen only for 1 and 2 components, so 3- and 4-component f32 varyings are iterated
  as 2+1 and 2+2 pieces, each its own dependent read.
- **[HW]** The A8 needs an explicit wait (dependent-read counter 0) between the coordinate iterator and the texture
  sample. Without it the texels were wrong and changed from run to run; with it the program is identical to Apple's
  textured fragment program. Only counter 0 is used; reads go in batches of eight, each waited for. Counter 1 is
  uncaptured; refusing it had refused 14 of WebRender's 31 shader variants.
- **[HW]** A no-perspective port read back zeros and was undone. Zink's blitter now uses perspective interpolation
  (w = 1, so the result is the same) and no texel fetch, which fixed the desktop's `glReadPixels`.
- **[iOS]** **Flat varyings:** in the capture of a flat varying, Apple's A8 program reads it with an 8-byte
  instruction of the same family as the perspective iterator, with a different extension byte; its fields are not
  fully decoded and we do not emit it yet. The A9's flat-load instruction appears in no A8 capture (searched over
  several thousand capture files), but our A8 path still uses it. Whether that works on the A8 is open, and it is
  the leading suspect for the vertex-texture zeros
  ([OPEN-PROBLEMS.md](OPEN-PROBLEMS.md#vertex-textures)).
- **[HW]** Saturated varyings are iterated, then saturated in the ALU (the saturating iterator is uncaptured).

## The texture sample instruction

A 12-byte instruction, the same length in fragment and vertex programs **[iOS]**:

| Byte | Bits | Meaning |
|---|---|---|
| 1 | 7:6 | sampler slot, low two bits |
| 1 | 5 | 32-bit result (else a 16-bit "narrow" result) |
| 1 | 4:3 | components written, minus one |
| 1 | 2 | result in register bank 1 (vertex form) |
| 4 | all | the image's common-store dword × 2 (images in 4-dword slots from 0) |
| 5 | 2:1 | sampler slot, high two bits; slot S = byte1[7:6] \| byte5[2:1] << 2, in 4-dword units |
| 6 | 7, 6:4, 2 | bit 7 set; bits 6:4 the mode (0 implicit LOD, 1 bias, 2 explicit LOD, 3 gradients, 4 cube); bit 2 = read (integer addressing, `texelFetch`); plain sample, float read and integer read differ here |
| 7 | 2 | coordinate in register bank 1 (vertex form); a separate value means "level in the register after the coordinate" |
| 10 | all | the LOD operand: fragment programs have one value for constant level 0 and one for level from a buffer; the vertex stage has its own constant-level-0 value |

- **[iOS]** A short single-image form names no slots: the image is at common dword 0, the sampler at dword 4.
- **[iOS]** The 32-bit-result sample, needed when the result feeds arithmetic, was found in Apple's own R32F and
  RGBA8UI load programs.

## Texture state and the multi-image layout

- **[HW][iOS]** The A8 texture unit takes **Rogue texture state** (image words 0/1 and sampler words 0/1), not the
  A9's three-qword state. Sending A9 state made it read garbage addresses. Further rules from captures:
  `mipmaps_present` only with several levels; `alpha_msb` clear for 8-bit RGBA/BGRA (and clear in Apple's RGBA32F
  and RGBA32I states); the sampler is 4 dwords.
- **[iOS][HW]** **Common-store layout:** all image states first, in 4-dword slots from dword 0, then the samplers.
  With one shared sampler it sits at slot N after N images; with one sampler per texture, texture j's is at slot
  N + j. Two images: image 0 at dword 0, image 1 at dword 4, sampler at dword 8 (checked pixel by pixel on the
  device). Seven textures share texture 0's sampler, as Apple's seven-texture program does. When the common store
  starts with other data (a blend colour, storage pointers), the images start after it. Apple waits between
  samples of different images.
- **[HW]** Two earlier readings were wrong and are superseded: "image k at dword 8k, sampler at 4", and a
  "sampler first" layout for four or more images, which read all zeros. Apple's layout is now the default for every
  program with two or more images.
- **[KC]** Layout rule in Apple's texture constructor: every texture type (1D to 3D, cube, arrays, MSAA) is
  twiddled; linear only for texture buffers, buffer- or IOSurface-backed textures and 4:2:2 formats.

### Cube maps

- **[iOS]** Apple builds the direction in three temporaries (FMAs and a move) and samples in mode 4: there is no
  cube-coordinate instruction, the hardware picks the face. Cube state counts cubes (depth 0 for one cube), unlike
  upstream Rogue. The face stride is one face's mip chain rounded up to 4 KiB; 2D arrays the same **[KC][iOS]**.
- **[iOS]** Only the narrow cube form (result straight to the output) is captured. A cube sample whose result feeds
  arithmetic is refused ([OPEN-PROBLEMS.md](OPEN-PROBLEMS.md#r8-load-and-cube-arithmetic-for-firefox)).

### texelFetch and texel buffers

- **[iOS][HW]** A fragment `texelFetch` is Apple's `read()`: the integer coordinate is converted to float and
  sampled with the read bit through a fetch sampler. That sampler is a program constant: point filtering,
  non-normalised coordinates, clamp to edge, LOD 0..0, no bias. (An earlier reading from the compiler binary,
  normalised with LOD 0 to max, is in no capture and is superseded.) RGBA8, RGBA32F and RGBA32I read every texel at
  level 0 **[HW]**.
- **[HW]** Uniform texel buffers are a linear 2D image 4096 texels wide; the program folds the index to 2D and uses
  the fetch. This is the GL PBO upload path WebRender uses.

## Vertex-stage sampling

- **[KC]** Apple builds vertex texture state exactly like fragment state; a sample without LOD in a stage without
  derivatives becomes explicit level 0.
- **[iOS]** Apple's vertex sample is the same 12-byte form with three differences: coordinate and result are in
  register bank 1 (byte 1 bit 2, byte 7 bit 2), the result overwrites the coordinate registers, and byte 10 holds
  the vertex constant-level-0 value. An earlier form inferred from the binaries (bank 0, level in a register) is
  wrong.
- **[iOS]** The vertex PDS loads three blocks: the image state into common dwords 0-3, the sampler into 4-7, and the
  constants (including the 0.0 level) after them.
- **[HW]** The A9's own vertex sample form locked the A8's TA (it recovered); no A8 program contains it. Mesa
  carries Apple's captured form behind an opt-in; it has not run on the GPU yet. Status in
  [OPEN-PROBLEMS.md](OPEN-PROBLEMS.md#vertex-textures).

## Draw control words

- **[KC]** These are now identical to Apple's captured draw: `PPP_CTRL` bit 9 (draw clipped edges) set; the index
  list with no split count and index size 0 when not indexed; stream-out word 1 = data 1, temps 1, without the A9's
  bit 14. The TA/3D record "trace" words carry Metal's trace-object ID, which the firmware appears not to need
  **[INF]**.
- **[iOS]** Apple's context-store PDS has upstream Rogue's shape, but the USC save and restore programs are in no
  capture, so there is no partial render on the A8 yet.
