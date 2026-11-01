#!/bin/sh
# Builds the Vulkan tests vk-compute-test, vk-fx, vk-play and vk-tri (arm64, against the
# Debian userland of the device chroot) in the Mesa build container:
# mesa/build-vk-test.sh OUT_DIR
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
podman run --rm -v "$HERE:/src:ro" -v "$OUT:/out" localhost/orchard-mesa-g9p:trixie sh -c '
    for s in /src/shaders/*.comp; do
        n=$(basename $s .comp)
        glslangValidator -V --vn ${n}_spv -o /tmp/$n.spv.h $s >/dev/null || exit 1
    done
    glslangValidator -V --vn vk_fx_spv -o /tmp/vk-fx.spv.h /src/vk-fx.comp >/dev/null || exit 1
    for s in /src/shaders/gfx/*; do
        n=$(basename $s | tr . _)
        glslangValidator -V --vn ${n}_spv -o /tmp/$n.spv.h $s >/dev/null || exit 1
    done
    for t in vk-compute-test vk-fx vk-play vk-tri; do
        gcc -O2 -Wall -ffp-contract=off -I/tmp -o /out/$t /src/$t.c -lvulkan -lm || exit 1
    done'
ls -la "$OUT/vk-compute-test" "$OUT/vk-fx" "$OUT/vk-play" "$OUT/vk-tri"
