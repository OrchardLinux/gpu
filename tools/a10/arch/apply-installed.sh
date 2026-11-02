#!/bin/sh
# The A10 GPU on an installed Omarchy A, until the product ships it: the GPU
# firmware, the Mesa fork's Vulkan driver (build-vk.sh) and the session
# switch. Run against the booted installed system (orchard exec reaches it
# as its user; sudo needs the user's password):
#
#   SUDO_PASSWORD=... tools/a10/arch/apply-installed.sh
#
# The kernel must already have the GPU driver (orchard main from b5e3769,
# the GPU node on every A10 board from 25b46df). Afterwards log out and in.
# With the GPU's render node and the driver present the session runs Labwc
# on wlroots' GLES2 renderer (Zink); otherwise pixman as before. The shell
# stays on Qt's software renderer (on the GPU it hung the A10, 2026-11-02);
# pickers draw with the GPU instead of llvmpipe.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../out/arch
FW=$HERE/../rootfs/lib/firmware/apple/gfx-t8010.bin
: "${SUDO_PASSWORD:?set SUDO_PASSWORD to the password of the installed system user}"
for f in "$FW" "$OUT/libvulkan_powervr_mesa.so" "$OUT/powervr_mesa_icd.json"; do
    [ -f "$f" ] || { echo "missing $f (README: the firmware; build-vk.sh)" >&2; exit 1; }
done
orchard push "$FW" /tmp/gfx-t8010.bin > /dev/null
orchard push "$OUT/libvulkan_powervr_mesa.so" /tmp/libvulkan_powervr_mesa.so > /dev/null
orchard push "$OUT/powervr_mesa_icd.json" /tmp/powervr_mesa_icd.json > /dev/null
orchard push "$HERE/installed-root.py" /tmp/gpu-installed-root.py > /dev/null
orchard exec -- sh -c "printf '%s\n' '$SUDO_PASSWORD' | sudo -S -p '' python3 /tmp/gpu-installed-root.py"
