# a8-vk-ladder: a Vulkan escalation suite for the A8

One program, one process per rung. Each rung exercises one more piece of the driver than the one before
(clears, a triangle, push constants, vertex and index buffers, uniform buffers, compute, large targets,
blending, depth, textures and their layouts, render-to-texture, load passes, cube maps, big meshes, and
vkmark's own shaders), and checks every pixel or value on the CPU. It was the bring-up and regression
test for the A8 Vulkan driver on the iPod touch 6 (N102) and is part of the A8 tester kit; see
[a8/n102/README.md](../../../a8/n102/README.md).

Each rung prints exactly one line, `RESULT <rung> PASS|FAIL|TIMEOUT|SKIP <detail>`, and exits 0 (pass or
skip), 1 (fail) or 3 (timeout). Before every step that enters the kernel driver it prints and flushes
`STEP <rung> +<ms> <what>`, so a hang shows where it stopped. `list` prints the rungs with their hang
risk, from low to highest; run them in that order on new hardware.

## Build

The fragment, vertex and compute shaders are the `l_*` files. Compile them into headers with
`glslangValidator`, then build against the Vulkan loader (aarch64 Linux):

```sh
for s in l_*.vert l_*.frag l_*.comp; do
  n=${s%.*}_${s##*.}
  glslangValidator -V --vn "$n" "$s" -o "$n.h"
done
cc -O2 -Wall -I. a8-vk-ladder.c -o a8-vk-ladder -lvulkan -lm
```

## Run

Against a Mesa build with the A8 (PowerVR) Vulkan driver, for example
`VK_DRIVER_FILES=.../powervr_icd.json PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 ./a8-vk-ladder tri64`.

| Variable | Effect |
|---|---|
| `A8_LADDER_TIMEOUT_MS` | fence wait per submission (default 5000); on expiry the rung prints TIMEOUT and exits without teardown |
| `A8_LADDER_TEARDOWN=1` | destroy the device and instance explicitly after the RESULT line |
| `A8_SMOKE_NOCHECK=1` | skip the result checks (for runs where nothing executes, such as a fake winsys) |
| `A8_VKMARK_SHADERS` | directory of vkmark's SPIR-V for the `vkm*` rungs (default `<bin>/../vkmark/data/shaders`); missing shaders make those rungs SKIP |

The `high` and `highest` rungs can hang the GPU on a driver that is not ready for them; the comments in
the rung table say what each one risks.

Licence: MIT (SPDX headers in the files). Written with AI assistance (Claude).
