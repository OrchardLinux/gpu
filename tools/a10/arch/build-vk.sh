#!/bin/sh
# Build the Mesa fork's Vulkan driver (only that) against Arch Linux ARM, in
# its own build directory of the Mesa checkout (build-alarm), and stage it
# with its loader manifest in ../out/arch:
#
#   tools/a10/arch/build-vk.sh PATH/TO/OrchardLinux/mesa
#
# Needs the image from Containerfile.build (orchard-gpu-alarm-build).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
MESA=$(cd "${1:?usage: build-vk.sh MESA_DIR}" && pwd)
OUT=$HERE/../out/arch
mkdir -p "$OUT"
podman run --rm -v "$MESA:/mesa" -v "$OUT:/out" localhost/orchard-gpu-alarm-build sh -euc '
    cd /mesa
    [ -d build-alarm ] || meson setup build-alarm --prefix=/usr --buildtype=debugoptimized \
        -Dplatforms=wayland -Dvulkan-drivers=imagination -Dgallium-drivers= \
        -Dopengl=false -Degl=disabled -Dgbm=disabled -Dglx=disabled -Dgles1=disabled \
        -Dgles2=disabled -Dllvm=enabled -Dvideo-codecs= -Dtools= -Dvulkan-layers= >/dev/null
    ninja -C build-alarm > /tmp/ninja.log || { tail -40 /tmp/ninja.log; exit 1; }
    strip --strip-unneeded -o /out/libvulkan_powervr_mesa.so \
        build-alarm/src/imagination/vulkan/libvulkan_powervr_mesa.so
    sed "s#\"library_path\": \"[^\"]*\"#\"library_path\": \"/usr/lib/libvulkan_powervr_mesa.so\"#" \
        build-alarm/src/imagination/vulkan/powervr_mesa_icd.*.json > /out/powervr_mesa_icd.json
    readelf -d /out/libvulkan_powervr_mesa.so | sed -n "s/.*NEEDED.*\[\(.*\)\]/\1/p" | tr "\n" " "'
echo
ls -la "$OUT"
