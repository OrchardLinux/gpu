#!/bin/sh
# Build the Vulkan test programs (mesa/vk-*.c) against Arch Linux ARM, for
# the Arch root and the installed Omarchy A, into ../out/arch:
#
#   tools/a10/arch/build-vk-tests.sh
#
# Needs the image from Containerfile.build (orchard-gpu-alarm-build).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../out/arch
mkdir -p "$OUT"
podman run --rm -v "$HERE/../mesa:/src:ro" -v "$OUT:/out" localhost/orchard-gpu-alarm-build sh -euc '
    for s in /src/shaders/*.comp; do
        n=$(basename $s .comp)
        glslangValidator -V --vn ${n}_spv -o /tmp/$n.spv.h $s >/dev/null
    done
    glslangValidator -V --vn vk_fx_spv -o /tmp/vk-fx.spv.h /src/vk-fx.comp >/dev/null
    for s in /src/shaders/gfx/*; do
        n=$(basename $s | tr . _)
        glslangValidator -V --vn ${n}_spv -o /tmp/$n.spv.h $s >/dev/null
    done
    for t in vk-compute-test vk-fx vk-play vk-tri; do
        gcc -O2 -Wall -ffp-contract=off -I/tmp -o /out/$t /src/$t.c -lvulkan -lm
    done'
ls -la "$OUT"/vk-*
