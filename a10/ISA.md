# A10 (applegpu_g9p) shader ISA notes

The A10's shader cores run Apple's own instruction set, not Rogue USC
(REFERENCE.md, "Shader ISA: Apple, not Rogue"). A Mesa backend needs an
encoder for it. These notes characterize the encoding from the output of
Apple's offline compiler, black-box: compile small kernels that differ in one
thing and compare the code.

## Method

- **Compiler:** Xcode's downloadable Metal toolchain
  (`xcodebuild -downloadComponent MetalToolchain`): `metal` → AIR,
  `metallib`, then `metal-tt -arch applegpu_g9p` → a Mach-O GPU executable.
  Each function is a nested Mach-O whose `__TEXT,__text` is USC code
  (byte-identical to what iPadOS loads, COMPUTE.md). The toolchain only runs
  on macOS; nothing of it is redistributed.
- **`tools/isa/g9p-text.py FILE.g9p.bin`:** prints each function's code as
  little-endian 16-bit words.
- **`tools/isa/explore.py PROBES.metal`:** compiles every kernel line of a
  probe file in its own library and pipeline and prints `name: code`.
  metal-tt compiles every function of a library, names each `_agc.main` and
  keeps no order, so one kernel per library is the only unambiguous mapping.
- **Probes:** `tools/isa/probes/*.metal`, one kernel per line.
- **Bit mapping:** for an operand, compile the same kernel with the operand
  set to each power of two; each value flips exactly the encoding bits that
  hold that operand bit.

Code is 16-bit granular and ends with `0x8000` at the start of a 64-byte
block, after `0xc000` padding. `explore.py` prints code with that padding
removed, so the listings below show `… 0000 8000`.

## Instruction length

**Bit 8 of every 16-bit word means another word follows.** An instruction
is the run of words up to and including the first word with bit 8 clear.
This splits all 98 streams of the probe corpus exactly onto their final
`0x8000` (`tools/isa/segment.py`; `tools/isa/solve-lengths.py` was the
constraint search that pointed to it). Consequences:

- Every word carries 15 payload bits (0–7, 9–15); operands spread over
  several words, so a field's bits are split around bit 8.
- `0x8000` (end of program) and `0xc000` (padding) are 1-word instructions;
  so is `0x004d` (the wait after loads).
- The two words `0154 0038` that follow a move-immediate belong to it (the
  move is `0198 03rr W2 W3 [W4] 0154 0038`).

## Move immediate (`probes/imm.metal`)

`o[0] = IMM` compiles to a fixed store sequence around one instruction that
loads the constant, `0198 0300 W2 W3 [W4]` (words, little-endian):

| Immediate bits | Encoding |
|---|---|
| 0–5 | W2 bits 1–6 (W2 base `0x0101`) |
| 6–8 | W3 bits 1–3 (W3 base `0x0120`) |
| 9 | W0 bit 13 (`0x0198` → `0x2198`) |
| 10 | W3 bit 4 |
| 11–13 | W3 bits 12–14 |
| 14, 15 | W3 bits 6, 7 |
| 16–23 | W4 bits 0–7 |
| 24 | W3 bit 15 |
| 25–31 | W4 bits 9–15 (W4 base `0x0100`) |

W3 bit 0 marks the 32-bit form: W4 is present only when the value needs bits
16–31. So instruction length is encoded in the instruction itself, and the
immediate is scattered in small fields around fixed opcode bits.

## Instruction boundaries and the store (`probes/seq.metal`)

Each additional `o[k] = constant` adds the same six words, which splits the
code into instructions:

| Words | Reading |
|---|---|
| `0198 03rr W2 W3 [W4]` | move immediate (above); destination register in W1: `0x0300 + 2·r` (r0, r1, r2 for three constants) |
| `0154 0038` | a 2-word instruction after each move (`0128 0039` for 8/16-bit data): likely a move or conversion into the store's data registers |
| `2s12 0rr0 8ooo [W3]` | device store. W0 bits 11–15: size and count (1 u8, 2 u16, 4 u32, 5 2×u32, 6 3×u32); W1: data register (`0x0180`, `0x0182`) and buffer (`0x0580` for buffer 1); W2 low bits: element offset (`o[1]` → `8001`, `o[5]` → `8005`); `o[1000]` → `81e8 0003`, so larger offsets take an extra word |
| `0900 01xx 0000` | precedes the stores; the middle word varies with the kernel |

- **Empty kernel:** `0100 0140 0000 8000`: the minimal end sequence.
- **Common prologue:** `1181 8189 4100 acb7 01c8 0302 0101 0120 46d1` (the
  second word is `8191` or `0189` in other kernels). Probably the
  argument-table and buffer-address setup.
- **Common epilogue:** `21c8 03rr 01rr 46d2 0100 01xx 0000 8000` (with the
  padding before `8000` removed, see the program frame).

## Loads and two-source ALU (`probes/basic.metal`)

- **Load:** the same `?312` opcode as the store; W1 bit 7 (`0x80`) marks a
  store, bit 10 up the buffer (`0x0100` buffer 0, `0x0500` buffer 1), bits
  1–6 the register. `o[0] = i[0]` is `2312 0500 8000` (load), `004d`, then
  `2312 0180 8000` (store); `004d` is a one-word wait on the load. Loading two
  words is `2b12 0500 8000`.
- **Two-source ALU:** `3199 03dd SSSS 00op` (4 words), the operation in the
  low byte of the last word:

  | Op | Low byte | W2 |
  |---|---|---|
  | integer add | `a1` | `8184` |
  | integer sub | `a5` | `8580` (operand order / negate bits differ) |
  | integer mul | `a2` | `8184` |
  | and / or / xor | `c8` / `ce` / `c6` | `8184` |
  | float add / mul | `44` / `48` | `8184` |

- **Three-source:** float FMA is 5 words, `399a 0300 8580 0188 004c`.
- **Shift left** and **add immediate** compile to other, longer sequences
  (`1199 0302 853f 0120 …`, `1199 0300 810b 0120 09a1 0070`).

## Program frame

With the length rule, every compute kernel so far has the same frame:

| Instruction | Meaning |
|---|---|
| `1181 8xx9 4100 acb7` | prologue (W1 varies: `8189`, `8191`, `0189`) |
| `01c8 03rr 0101 0120 46d1` | `rr` = 2 × registers used (2 for one live value, 4 for two, 6 for three) |
| body | loads, ALU, stores |
| `0900 01oo 0000` | before the stores: `oo` = byte offset from this instruction to the epilogue (`st_1357`: byte 30 + 12 = 42, the `21c8`) |
| `21c8 03rr 01rr 46d2` | epilogue, register count again |
| `0100 01pp 0000` | jump forward `pp` bytes to the end word |
| `c000`… | padding up to the next 64-byte boundary |
| `8000` | end, the first word of that 64-byte block |

## Control flow (`probes/cmp.metal`, `probes/branch.metal`)

Divergence is handled with an execution-mask stack kept in a register; the
"register count" words of the program frame are its instructions. The
compiler takes the first register after the kernel's own as the stack
register `st` (`03ss` = `0x0300 + 2·st`).

| Words | Instruction |
|---|---|
| `01c8 03ss 0101 0120 46d1` | start the mask stack in `st` (program start) |
| `1181 W1 W2 a1cc 0070` | compare r0 with an immediate; the immediate takes the move-immediate fields (W0 bit 13, W1 bits 1–6, W2 bits 1–3, long form with an extra word) |
| `3181 8180\|a<<2\|b<<10 a0cc` | compare two registers |
| `21c8 03ss 01ss' 46d1` | push: disable the lanes whose compare failed (`66d1`: whose compare passed); `ss'` = `st << 2` |
| `21c8 03ss 01ss' 46d4` | else: flip the lanes of the innermost level |
| `21c8 03ss 01ss' n6d2` | pop levels: `46d2` one, `86d2` two (`ss'` = `0x80 \| st << 2`) |
| `0900 01oo 0000` | jump forward `oo` bytes if no lane is active (to the matching else or pop) |
| `0100 01oo 0000` | jump forward unconditionally; `0101 ffc1 feff` in loops is a backward jump (offsets: "Jump offsets") |

Integer conditions (low byte of the compare's last word):

| `cc` | Condition |
|---|---|
| `b6` / `b7` | unsigned < / > |
| `bd` | == |
| `be` / `bf` | signed < / > |

`<=` and `>=` are the opposite condition with the inverted push (`a <= b` is
`!(a > b)`); against an immediate the compiler also adjusts the constant
(`a < 7` → `!(a > 6)`). The same op space holds umin `b2`, umax `b3` and smin
`ba` (5-word ALU form). Float compares are `1181 … 21cc x070` with `55` ==,
`59` <, `5d` <=; bit 12 of the last word selects the ordered/unordered
variant (not mapped yet).

### Loops and selects (`probes/select.metal`)

| Words | Instruction |
|---|---|
| `21c8 03ss 01ss' 86d0` | loop start: pushes two levels (loop, break) |
| `21c8 03ss 01ss' 86d7` | break the lanes whose compare failed (`a6d7`: passed) |
| `0101 W1 W2` | jump back while any lane is active. Offset relative to the instruction, 8+7 bits per word (W1 bits 0–7, 9–15; W2 the same), sign-extended, bit 0 set |
| `21c8 03ss 01ss' 86d2` | after the loop: pop both levels |
| `399a 03dd SSSS 01cc 60xx` | select: `dd = c` where `a xx b` (W2 `a`, `b`; W3 `c`); condition codes as for compares |
| `21f8 03dd 01dd' 0154 0038` | then `dd = d` where that compare failed (`01f8 … W2 W3 0154 0038`: an immediate, move-immediate fields) |
| `1199 03dd W2 0120 09a1 0070` | add immediate: `dd = s + imm`, W2 = `0x0101 + imm << 1 + s << 10` |

Source words carry two flags: bit 7 for the first register and bit 15 for
the second. The compiler sets them exactly where the value is dead
afterwards (`8580` vs `0500` for r0, r1), so they read as last-use hints.
With them the select's W0 is `399a`, without `399e`. In immediate forms the
register sits in bits 10+ and the immediate in bits 1–6. A trailing word
(`0070`, `0058`) says which operand the immediate replaces.

`g9p.assemble()` resolves the jumps from labels; it reproduces the
compiler's `br_ifelse` word for word.

## Jump offsets (`probes/longjump.metal`, 2026-10-31)

Jumps (`0900` none active, `0100` always, `0101` any active) carry a byte
offset from the jump instruction in two words. Bit 8 of each word is the
continuation flag, so **offset bit 8 sits in bit 0** (offsets are even):
word 1 = `(off & 0xfefe) | 0x100 | (off >> 8 & 1)`, word 2 the same for
bits 16-31. Samples (if-bodies of growing size): 250 → `01fa`, 328 →
`0149`, 538 → `031a`, 646 → `0386`, 968 → `03c9`, 3528 → `0dc9`; backward
-72 → `ffb9 feff`. The earlier reading ("8 + 7 bits per word", backward
"bit 0 set") was only right below 256 bytes; it made jumps of 256 bytes or
more land in the wrong place and hang the GPU.

## Graphics: first look (`probes/frag.metal`, `tools/isa/explore-render.py`, 2026-10-31)

Render pipelines compile to two functions (vertex, then fragment);
`explore-render.py` compiles `// pair VS FS` lines with a BGRA8Unorm
target. Observations, not yet tested on hardware:

| Words | Where | Reading |
|---|---|---|
| `141e`, `151e 01rr 00kk` | vertex | write register `rr` (bits 1-6) to output slot `kk`; the bare `141e` writes slot 0 from r0 |
| `155e c1rr 00kk` | vertex | the last output write (W0 bit 6, W1 `c1`) |
| `024d` | vertex | wait (second load group?) |
| `211c 0800`, then `8000` | fragment | colour output, then the end word directly (no jump-to-end frame) |
| `0198 01hh … 0154 0038` | fragment | moves into 16-bit half registers (`01hh`: half index), used to pack the colour as f16 for a BGRA8 target |
| `030a 0300 0080` | fragment | read (iterate) a vec4 varying into r0-; `130a 0304 0080` a vec2 into r2; followed by `004d` |
| `1308 0300 8000` | fragment | iterate the texture coordinate (feeding a sample) |
| `f518 0100 8108 0700 0200` | fragment | texture sample into half registers |
| `211c 6800` | fragment | read the fragment position |
| `0189 0100 8188 01a1 0a00` | fragment | pack/convert floats to halves (fs_uv) |

**On hardware (2026-10-31, `pvr-render-test FS_COLOR=r,g,b,a`):** the
captured triangle's fragment shader is two move-immediates of packed halves
into r0 (`0x38003400` = R 0.25, G 0.5) and r1 (`0x3c003a00` = B 0.75, A 1.0),
then `211c 0800` writes r0-r1 as RGBA16F; the BGRA8 target stores
`0xAARRGGBB`. Replacing the moves with our encoder renders any colour
exactly (red `0xffff0000`, (0.5, 0.25, 1) `0xff8040ff`, coverage
unchanged) **only with W1 `0x01xx`**, as Apple writes it. With the `0x03xx`
form compute code uses, red is lost and pixels go wrong: bit 9 of a
register operand matters for the fragment output registers. Re-patching
code at the same address between runs can leave stale instruction cache;
reload the module between such tests.

**f32 registers and fragment outputs (2026-10-31, `pvr-tri TRI_FS32`,
`TRI_FS_ALU`, TESTED):**

- In fragment shaders, **move-immediates into 32-bit registers must use
  W1 `0x0100 | 2r`** (as Apple's fragment code does: `0198 0102 … 3d00`
  writes r1). The compute form `0x0300 | 2r` gives wrong pixels (and
  disturbs neighbouring tiles), with any register. (This note used to say
  two-source ALU ops work with either form: the test multiplied by 2 and
  then by 0.5, an identity that passes when nothing is written. They do
  not; see "Fragment register bank" below.)
- **f32 → f16 output conversion**: `0189 01hh 0101|s<<10 7130 0b48 0070`
  writes half `hh` (of r0-r1, the colour output) = f32 r_s × 1.0, the 1.0
  an f16 immediate in the move-immediate's field layout (W2 low bits, W3
  `0x0120` base: `0x3c00` → `7130`). Apple's compiler emits the same form
  with other constants (`7120` = 0.5 in `fs_half`). Four of them and `211c
  0800` output an f32 colour exactly.
- **Register allocation of a USC task kicked by DOUTU**: the kick data's
  second word holds the temp count in bits 3-8, in units of 4 registers
  (Rogue's DOUTU_SRC0 `temps` field, bits 35-40). `0x10` (2 units) runs
  r0-r7 and breaks with r8-r11; `0x18`/`0x20` run r12-r15, `0x20` breaks
  with r20; `0x40` runs r28-r31; `0x80` does not make r40 work in these
  5-bit forms (above r31 needs an extension word: "Registers above r31"
  below). Apple's `0x10` everywhere fits its small
  shaders. Word = `DIV_ROUND_UP(registers, 4) << 3`
  (`pvr-tri TRI_FS_TEMPS`).
- **Vertex shaders are different**: their registers come from VDM_STATE5
  (the VDM_STATE word after the vertex output count), bits 10-15, in
  units of 2 registers; the vertex kick's DOUTU temps do not raise it.
  iPadOS's `0x1081` (4 units) gives r0-r7; Mesa's first vertex shader
  used r0-r10 and hung until the field was 6 (`0x1881`; 5 still hangs).
  Found by running Mesa's code in `pvr-tri` (`TRI_VS_HEX`, `TRI_VDM5`).
  The field's unit is 2, but round the count up to a multiple of 4: vertex
  shaders of 17 and 18 registers drew wrong values with the field covering
  them, and the same shaders passed at 20, 24 and 32 (four dEQP tests,
  2026-11-05; why is not known).
- Lesson: `pvr-tri` places programs at fixed offsets; a fragment shader
  longer than its slot ran into the vertex shader and hung the GPU, which
  looked like an encoding failure.

Vertex shaders in these probes load their inputs from a buffer with the
register-indexed address/load forms (`1189 …`, `3b10 …`): vertex inputs are
plain memory loads here.

## Source reach below r16 (dEQP-GLES2, 2026-11-05, A10)

Measured in vertex shaders on the A10. Another chip may differ, so test this
early on a new board: it shows up as wrong values, not as a hang or an error.

- **One source with an immediate reaches r15 only:** `1189` (address index),
  `1199` (add immediate, conversions, moves), `1181` (compare with immediate)
  and `199e` (shift). Their source sits at bit 10 of the word. Reading r16
  through `1199 0312 4101 0120 09a1 0070` gave wrong values, with no fault.
- **Two-source forms (`3199`, `3181`) reach the higher registers:** a move from
  r16 is `3199 dst 4140 00ce` (OR with itself). Vertex shaders of 20 to 23
  registers pass dEQP this way.
- **Memory address pairs must lie below r16:** a pair across r16 read the wrong
  memory.
- **Put the mask stack in r15 at most:** above it, vertex shaders drew wrong
  values or hung the geometry job.
- **Registers above r31 work in vertex shaders too,** through the forms in
  "Registers above r31" with W0 `3199`. Forcing values into r16-r29 passes dEQP.
- Fragment code uses a different encoding and is not covered by these limits.
  Compute was not measured; Mesa treats it like vertex code.

Mesa: `one_src()`, `low_reg()` and `alloc_pair()` in `g9p_compile.c`.

## Sampling (metal-tt, tested on dEQP, 2026-11-05)

Compile the Metal equivalent with `metal-tt -arch applegpu_g9p` before guessing
at an encoding: it answered all of this in minutes. The pipeline file must be
named `*.mtlp-json`.

| Words | Meaning |
|---|---|
| `f51a W1 W2 0700 0200` | fragment sample; W1 and W2 as in RENDER.md "Textures" |
| `f51a W1 W2 07c0\|r 0280` | explicit level from r, fragment (`07a0\|r`: bias) |
| `f51a W1 0100\|c<<9\|s 07c0\|r 8180 0108 0010` | vertex sample, level from r, coordinates in r[c].. |
| `fd1a ...` | cube; in a vertex shader W2 also has bit 15 |
| `7d08 0100\|dst_half 8000` | cube op, direction in r0-r2 (`8400` in a vertex shader) |

- **Level and bias are f16,** read from the low half of the register. Apple
  converts first (`1189 dst 0101|s<<10 01a0 0b44 0070`). An f32 there gives wrong
  values and looks right only at level 0.
- **In a vertex shader, writes to r0-r3 use W1 `0x01..`** and writes above use
  `0x03..` in Apple's code, and in `1199` the first register operand has the
  0x80 flag. Why is not known.
- **Register iterates before a wait have two words,** `1b08 0200 004d`: W1 without
  its continuation bit and no third word. With `... 0080` helper pixels get no value.
- **Only a program's first iterate to the sampler** (`1308 0300 8000`) gives helper
  pixels coordinates. A second one leaves them without, so its level is wrong where a
  quad leaves the primitive (dEQP samplers.multi_tex_2d). Later samples iterate into
  r0-r1 (`1308 0200 004d`) and sample from there.
- **Vertex compare samples** (`sample_compare` at a level, metal-tt): `151a w1 w2 87c5
  81c4 0108 8010`, W6 bit 15 besides W3 bit 15 and W4's half; random results without
  it. W0's top nibble is the result write mask (Apple 1, ours f). Apple's offset-only
  vertex sample also sets W6 bit 15, with the offset in an odd half (`81c5`), but ours
  breaks with it and works without. Compare plus offset (reference r2, offset r3 low,
  `81c4`, `4108`, `8010`) matches Apple word for word and still samples wrong texels.
- **Vertex kick data stays at four dwords:** VDM_STATE5's `vs_pds_data_size` 2 (eight dwords,
  for a third DOUTW of a constant into r2) hung the geometry job, with that kick and with the
  plain one alike. Per-view constants go into per-view programs instead (multiview).
- **VDM_STATE0 bits 1-2** (Rogue's flatshade_control): the vertex of a strip's triangle
  with the flat colour, 2 for the last provoking vertex, 1 for fans. Without it odd
  strip triangles took another vertex's colour; the DOUTI shade-model byte alone is
  not enough.
- **SIZEINFO2 bit 14** (Mesa calls it triangle merging off): with it set, ALU results of
  helper pixels outside the primitive are wrong, so computed coordinates sample wrong
  levels at the draw's edges (texture.units, derivate.*.texture). With it clear, quads on
  the shared diagonal of two triangles vary by one LSB between identical draws in rare
  runs (samplers.multi_cubemap, about 1 in 6). Meaning not settled.
- **3D samples** are `fb1a` (fragment and vertex), coordinates in three registers.
- **gl_FrontFacing:** `0198 dst 0131 0110 0154 0038` reads the winding, not the state:
  XOR it with the draw's front face.
- **Open:** cube samples in vertex shaders give results that depend on the
  vertex instance count, so some vertices are wrong.

## Derivatives, gradients, cube direction (metal-tt, 2026-11-06, TESTED with dEQP)

| Encoding | Meaning |
|---|---|
| `0198 dst 0100\|r<<2 0144 0200` | `dfdx`; r up to r31 |
| `0198 dst 0100\|r<<2 0144 0400` | `dfdy`. W3 bit 0 (`0145`) on the program's last derivative: helper pixels stop there |
| `f71a W1 8100\|coord<<9\|sampler 07e0 0080` | 2D array sample with gradients: f32 dx.s, dx.t, dy.s, dy.t in r0-r3; s, t, layer (uint) from `coord`. 2D: `f51a` |
| `2198 0100\|2d 0100\|r<<2 0154 0038` | Plain move. A vertex shader's cube direction into r2, r1, r0 **must** use this: a float add into r0-r2 gave half of the lanes wrong coordinates |
| `271a dst 8100\|coord<<9\|sampler 0600` | LOD query, array (`2d1b ... 0700 0200` on a cube), f32 in dst. Wrong on face edges with an array texture state |

A vertex shader's 2D array sample is `f71a`, W2 bit 15 set, as a cube's.
`gl_PointCoord` is a varying whose DOUTI has the pointsprite bit (bit 23 of its first data
word). Sample state must sit at its own 8-dword slot: a second state at dword +4 fails.

## Fragment register bank (`probes/fsops.metal`, `fsbranch.metal`, 2026-10-31, TESTED)

Fragment shaders keep their registers in a different bank from compute and
vertex shaders, and the instruction words say which bank each operand is
in. Mesa's fragment code used the compute forms and so computed nothing:
every result went to registers the colour output never read.

- **W0 bits 11-13 and W1 bit 9 are the bank bits.** Apple's compute and
  vertex code always sets them (`3199 03dd`, `1199 03dd`, `219c 03dd`,
  `399e 03dd`, `3181`, `1181`); its fragment code never does in register
  forms (`0199 01dd`, `0198 01dd`, `019e`, `01f8`, `0181`). Iterates,
  move-immediates and the f16 colour conversion all live in the fragment
  bank. Moving everything to it (Mesa `g9p_w0()`, `g9p_dst()`) makes fmul,
  fadd, ffma, the unary ops, conversions, integer ops and compares work.
  In immediate forms W0 bit 13 can be an immediate bit
  (`2199 0106 8901 0160 0948 0070` = x · 3.0), as for the move-immediate.
- On hardware (`pvr-tri TRI_FS32=0100,2 TRI_FS_ALU_ONCE=1 TRI_FS_W0=…`, one
  ×0.5): W0 `0189`/`0199` halve the colour; `1189`, `3189`, `1199`, `3199`
  leave it unchanged; `2189`, `2199` give garbage. With W0 bit 12 the op
  writes the other bank; with bit 13 it reads a source from it.
- The 6-word immediate forms (`0199 01dd 0101|s<<10 IMM 0948 0070`, f16
  immediate) multiply into f32 registers (`TRI_FS_MULH`).
- **Mask stack** (`fsbranch.metal` `fs_loop`): `01c8 010d 0101 0120 66d1`,
  `01c8 010d 011a 86d0`, `… a6d7`, `… 86d2`, `01c8 010d 019a 46d2`: W0
  `01c8` rather than `21c8`, and the stack in the upper half of a register
  (half 13 = r6 high; W2 names it as `0x0100 | half << 1`). Mesa follows
  (`g9p_st_dst()`/`g9p_st_src()`).
- Apple's own fragment if/else uses predicated instructions (`01fa`,
  `418e`, W0 bit 14) instead of the mask stack, and selects
  (`019a … 6059` + `01f8`). Mesa keeps the mask stack; it works once in
  the right bank.

**Iterate component count.** W0 bits 11-12 of an iterate are the count
modulo 4: Apple writes `0b08` for one component, `1308` for two, `0308`
for four. Mesa had `4 - count`, so a one-component iterate (`1b08`) wrote
three registers and overwrote two live values after it. Two components
(texture coordinates) coincided, which is why textures worked. It showed
up as selects that were right alone and wrong as soon as a varying was
read after them.

**Non-perspective iterates** count their component index without the W:
W1 bits 9-15 = c for `0108`, 1 + c for `0308` (perspective). Measured with
a constant (0.25, 0.5) in gl_FragCoord's varying: the non-perspective
iterate at 1 + c read the next component.

**Conditional discard** (`probes/discard2.metal`, `discard3.metal`): Apple
compares with a 4- or 5-word form whose W1 is `0100`, then `6004`:

| W3 [W4] | Condition (a = W2 bits 2-6, b = bits 10-14) |
|---|---|
| `435a 1000` / `425a` | float a < b / a ≥ b |
| `435e 1000` / `425e` | float a > b / a ≤ b |
| `4356 1000` / `4256` | float a == b / a ≠ b |
| `e2b9` / `a2b9` | integer a == b / a ≠ b |
| `e2b2`, `e2b3`, `e2ba` | unsigned <, unsigned >, signed < |

The fifth word is there exactly when W3 bit 8 is set; bit 8 (float) and
bit 14 (integer) negate. Mesa discards where the condition ≠ 0
(`a2b9` against a zero register). Its older `1181 … a1b7` compare made
`6004` discard nothing, and vk-tri's discard check accepted that.

**Tests**: `mesa/fsops.py` generates fragment shaders for 15 groups of ops
(arithmetic, rcp, sqrt, exp/log, sin/cos, floor/fract, selects, min/max,
integer ops, abs/sign, dot/length/normalize, smoothstep, branches and
loops) over a uniform vertex colour (`vk-tri TRI_VCOL`, `TRI_FS_SPV`,
`TRI_WANT`); all pass.

### Registers above r31 (`pvr-tri`, 2026-11-01, TESTED)

Fragment tasks address r0-r127; Apple's compiler uses up to r101 in
fragment code. The 5-bit register fields reach r31 only:

- As a **destination** the usual W1 `0x0100 | 2r` (r up to 127).
- As a **source** the operand word holds `r & 31` with bit 0 set, and an
  extension word after it holds `r >> 5`: `0x0100 | (a >> 5) << 1 |
  (b >> 5) << 9` for the first and second operand, the same form as
  uniform operands (`0x4100 | (u >> 5) << 1`).
- The task's temp count (DOUTU data word, above) must cover them:
  `DIV_ROUND_UP(registers, 4) << 3`.
- Tested in `pvr-tri` with r40, r77 and r100, written and read back.

Mesa uses them as "homes": when code generation runs out of r0-r31, a
value is stored above r31 after its definition (OR, which copies any bit
pattern: `0199 0100|2h 0100|s<<2|s<<10 00ce`) and moved back into a
temporary for each use (Mesa `g9p_mov_to_high()`, `g9p_mov_from_high()`).

## Fragment uniforms and loads (`probes/fsuni*.metal`, `fsload.metal`, 2026-10-31)

- **Uniform operands**: Apple's fragment code reads buffer constants from
  the common store directly as ALU operands: `0199 0106 8995 4100 0048` is
  r3 = U(5) x r2. The operand byte is `0x81 | (u & 31) << 2` (where a
  register would be), followed by an extension word `0x4100 | (u >> 5) <<
  1` (`fsuni3`: 160 dwords use extensions 1-4). The compiler packs only
  the used dwords; ours DMAs each buffer's first dwords to a fixed region
  (`G9P_FS_BUF_BASE` + 128 k) and moves them with `iadd U(u), zero`
  (`g9p_mov_uniform()`). TESTED through Zink (`gbm-kms-test
  GBM_FS_UNIFORM=1`, Hyprland's shaders).
- **Memory loads** in fragment code: Apple's are `2012`/`3812` (buffer-
  indexed, W0 bits 8-9 clear where compute's `2312` has them set). Ours
  (an address instruction reading the common store, then `0x0010 | size <<
  11` through the pair) hang, and the compute form `0x0310` reads zeros;
  not solved yet, the uniform path above avoids them.

## Transcendentals and float unary ops (`probes/trans.metal`, 2026-10-31)

Float unary form `2198 03dd 01ss 00op` (W0 `219c` without the last-use
bit): floor `40`, rcp `80`, rsqrt `81`, log2 `84`, exp2 `85`. Sine and
cosine as Apple's compiler emits them: `t = x / 2pi` (+ 0.25 for cos), `t =
(t - floor(t)) * 4`, `a = op82(t)`, `b = op86(a)`, result `a * b`.
Checked on hardware against the host's math for 64 inputs: relative error
at most 7e-7 (floor exact, rcp 4e-7, rsqrt 2e-7, log2 2e-7, exp2 7e-7, sin
8e-7, cos 1.2e-6). Applying op86 to `t` instead of op82's result, or
scaling by 2pi instead of 4, gives NaNs. Float register compares are
`3181 srcs 60cc` (`0x5d` is `>`, not `<=`: `if (a <= b)` compiles to
`!(a > b)`); `61cc 1000` negates.

## Register-indexed memory access (`probes/index.metal`, `index2.metal`, 2026-10-31)

`o[i] = v` with `i` in a register compiles to an address computation and a
load/store through a 64-bit address register pair:

| Words | Meaning |
|---|---|
| `1189 03dd W2 4100 01a1 W5` | `r[d]:r[d+1] = buffer base + (r[i] << shift)` |
| W1 `0300 \| 2·d` | destination pair (low register) |
| W2 low byte | buffer base, a uniform: `0x81 \| 2·half` (half = 16-bit common-store index: buffer 0 → `0x81`, dword 2 → `0x89`, dword 4 → `0x91`) |
| W2 bits 8–14 | index register: `0x01 \| i << 2` (as the address byte below) |
| W2 bit 15 | last use of the index register |
| W5 bits 13–14 | shift = log2(element size): u8 `0600`, u16 `2600`, u32 `4600`, u64 `6600` |
| `?310 aaRR 8800` | load/store through the pair: W0 bits 11–15 size (as `?312`); W1 high byte `0x01 \| a << 2` = address pair `r[a]`, bits 1–6 data register, bit 7 = store |

Observed W0 variants of the address instruction, `118d` and `518d`, follow
the same pattern as the program prologue (`1181`/`5185`) and look like
scheduling flags, not operands; with a base of `0x01` instead of `0x81`
(`ix_two`, `ix_three`) the meaning of W2's low byte is open. `0x81`-form
with W0 `1189` is the one to use until those are tested.

Apple's buffer layout with N buffers: addresses at common-store dwords 0,
2, 4, … and the thread count after them (prologue `0189` with one buffer,
`0191` with two: half 4 → dword 2, half 8 → dword 4).

## Tile read and blending (`probes/blend.metal`, `fbfetch.metal`, `fbfetch4.metal`, 2026-10-31)

Apple's GPU has no fixed-function blender: the compiler appends the blend to
the fragment shader, which reads the tile's current colour, and the draw is
marked translucent (ISPA/BA pass type 1; the `blend` capture differs from
`base` only there and in the shader). `tools/isa/explore-blend.py` compiles a
pipeline with any metal-tt colour attachment state (`blending_enabled`,
`source_rgb_blend_factor`, ..., `write_mask`) and prints the code; Metal's
`[[color(0)]]` fragment input gives the read alone.

| Words | Meaning |
|---|---|
| `211c 2800 \| h` | read the tile's four colour halves into halves h..h+3 (`2800`: r0-r1, `2804`: r2-r3, `2818`: r12-r13); then `004d` |
| `111c 2800 0002`, `111c 2900 0002` | read two components (x, y or z, w) into r0 |
| `0189 81dd 8hh1 01a0 0304 0070` | half hh (in units of halves, bit 15 = 16-bit source) to f32 r[dd / 2] |
| `0189 010h 8hh1 01a0 0304 0070` | half hh to half h (saturate) |
| `418e`/`018a` ... | half-precision multiply-adds with half operands (Apple blends in f16; operand forms not decoded) |

Tested with `pvr-tri TRI_PASS=1 TRI_FS_HEX` and `pvr-render-test FS_CODE`
(the `blend` capture with our code), reloading the GPU between runs:

- The read works into r0-r1 and r2-r3, in iPadOS's job and in ours, with
  pass type 0 or 1.
- The half-to-f32 conversion wrote r0, r1 and r2 (Apple's compiled `g4`
  probe, four conversions into r0-r2, gives the exact result); into r3 or
  r4 it left the register unchanged. Whatever selects higher destinations
  is not known, so Mesa converts in integer code (MESA.md "Blending").
- A test shader's output that is neither the clear nor the triangle colour
  makes pvr-tri poll its full 3 s: "after 3000.0 ms" is not a hang. Its
  "first other pixel" line has the value.

## On hardware

`tools/isa/gen-tests.py OUTDIR` writes kernels assembled by `g9p.py` from the
encodings above only; `pvr-compute-test USC.bin INDEX VALUE` runs one on the
GPU through the powervr UAPI and checks the stored word.

| Kernel | Result |
|---|---|
| `imm32` (`o[7] = 0xdeadbeef`) | 25/25 |
| `iadd`, `imul`, `xor`, `mulxor` (chained) | 25/25 each |
| `reuse` (destination = source register) | 25/25 |
| `regs4` (move to r3 with 4 registers, store r3) | 25/25 |
| `imm32` with the code at USC offset 0x1c0 | 25/25 |
| if/else on `r0 == 5` (true and false), `ult`, `slt`, `ugt` register compares | 10/10 each, one hang in `if_ugt_f` |
| loops (`3^5`, `3^1`, a while loop summing 10..2) and selects (true, false, immediate) | 10/10 each |

An earlier assembler put `8000` directly after the final jump, so the jump
landed past the end of the program; about one run in twelve then hung the
GPU. Apple's compiled kernel never failed in 335 runs. With `8000` at the
jump target, as Apple lays it out, the kernels above pass every run. The USC
instruction cache is not an issue: different kernels alternating at one
address pass. The remaining rare hang (Apple's kernel once in about 360 runs, the
assembled ones once in about 260) was the firmware's event ring filling
after 255 jobs; the driver now acknowledges events (COMPUTE.md).

## Next

- Register fields: destination and source register numbers (kernels with
  many live values; varying buffer indices).
- The fixed store sequence (`1181 8189 4100 acb7 …`, buffer address load,
  `0154 0038` store?) split into instructions; instruction lengths.
- ALU opcodes (integer, float, conversions), comparisons and branches.
- Fragment-shader outputs, interpolation, texture sampling: first
  encodings in "Graphics: first look"; next is a hardware test through the
  Linux render path (pvr-render-test) with our own fragment code.
