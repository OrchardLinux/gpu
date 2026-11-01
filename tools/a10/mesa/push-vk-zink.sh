#!/bin/sh
# Rebuild build-zink and push only the Vulkan driver (compiler/driver
# changes) into the Debian unstable chroot of deploy-zink.sh:
#   mesa/push-vk-zink.sh MESA_DIR [COMMAND...]
set -eu
MESA=$1; shift
podman run --rm -v "$MESA:/mesa" localhost/orchard-mesa-g9p:sid sh -c '
    ninja -C /mesa/build-zink >/dev/null || { ninja -C /mesa/build-zink | grep -E "error|FAILED"; exit 1; }
    strip --strip-unneeded -o /mesa/build-zink/vk-stripped.so \
        /mesa/build-zink/src/imagination/vulkan/libvulkan_powervr_mesa.so'
orchard push "$MESA/build-zink/vk-stripped.so" \
    /run/sid/usr/lib/aarch64-linux-gnu/libvulkan_powervr_mesa.so > /dev/null
[ $# -eq 0 ] || orchard exec -- chroot /run/sid sh -c "$*"
