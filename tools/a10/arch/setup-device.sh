#!/bin/sh
# The Omarchy A GPU experiment on a booted tools/a10 payload (GPU driver
# loaded): an Arch Linux ARM root in the iPad's RAM (/run/arch, from
# Containerfile.runtime) with Arch's own Mesa, the fork's Vulkan driver
# (build-vk.sh), Omarchy A's shell and Labwc theme from an omarchy-a
# checkout, and the start script:
#
#   tools/a10/arch/setup-device.sh PATH/TO/omarchy-a
#
# The root is the compressed squashfs of build-root.sh, read-only, with a
# RAM overlay for what changes. /run is RAM: again after every boot.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OMARCHY=$(cd "${1:?usage: setup-device.sh OMARCHY_A_DIR}" && pwd)
OUT=$HERE/../out/arch
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
[ -f "$OUT/libvulkan_powervr_mesa.so" ] || { echo "run build-vk.sh first" >&2; exit 1; }
[ -f "$OUT/root.sqfs" ] || { echo "run build-root.sh first" >&2; exit 1; }

if ! orchard exec -- test -d /run/arch/usr; then
    orchard push "$OUT/root.sqfs" /run/arch.sqfs > /dev/null
    orchard exec -- sh -c 'mkdir -p /run/arch-ro /run/arch-rw/upper /run/arch-rw/work /run/arch &&
        mount -t squashfs -o loop,ro /run/arch.sqfs /run/arch-ro &&
        mount -t overlay overlay -o lowerdir=/run/arch-ro,upperdir=/run/arch-rw/upper,workdir=/run/arch-rw/work /run/arch &&
        for d in dev proc sys; do mount --bind /$d /run/arch/$d; done &&
        mount --bind /dev/pts /run/arch/dev/pts && mount -t tmpfs tmpfs /run/arch/tmp &&
        mkdir -p /run/arch/run/user/0 && chmod 700 /run/arch/run/user/0'
fi

# The fork's Vulkan driver beside Arch's Mesa
orchard push "$OUT/libvulkan_powervr_mesa.so" /run/arch/usr/lib/libvulkan_powervr_mesa.so > /dev/null
orchard exec -- mkdir -p /run/arch/usr/share/vulkan/icd.d
orchard push "$OUT/powervr_mesa_icd.json" /run/arch/usr/share/vulkan/icd.d/powervr_mesa_icd.json > /dev/null

# Omarchy A's shell (OMARCHY_PATH) and Labwc look, as its dev autostart uses them
tar -C "$OMARCHY/desktop/shell" --exclude=__pycache__ -czf "$TMP/shell.tar.gz" .
orchard push "$TMP/shell.tar.gz" /run/arch/root/shell.tar.gz > /dev/null
orchard exec -- sh -c 'rm -rf /run/arch/opt/omarchy && mkdir -p /run/arch/opt/omarchy &&
    zcat /run/arch/root/shell.tar.gz | tar xf - -C /run/arch/opt/omarchy && rm /run/arch/root/shell.tar.gz &&
    mkdir -p /run/arch/root/.config/labwc /run/arch/root/.local/share/themes &&
    cp -r /run/arch/opt/omarchy/labwc-theme/* /run/arch/root/.local/share/themes/ &&
    cp /run/arch/opt/omarchy/labwc-rc.xml /run/arch/root/.config/labwc/rc.xml'
orchard push "$HERE/start-labwc.sh" /run/start-labwc.sh > /dev/null
orchard exec -- chroot /run/arch sh -c 'VK_LOADER_DEBUG=error PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 \
    vulkaninfo --summary 2>&1 | grep -E "deviceName|driverName|apiVersion" | head -3'
echo "ready: /run/start-labwc.sh [gpu|cpu] [SECONDS]"
