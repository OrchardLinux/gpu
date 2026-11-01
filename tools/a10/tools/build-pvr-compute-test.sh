#!/bin/sh
# Builds a powervr UAPI test tool (static arm64) in the kernel toolchain
# container, against the powervr UAPI header of the shared kernel tree.
#
#   ORCHARD=~/orchard build-pvr-compute-test.sh [pvr-compute-test|pvr-render-test|pvr-fx]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
HW=$(cd "${ORCHARD:?set ORCHARD to an orchard checkout}/kernel" && pwd)
PIN=$(sed -n 's/^commit *= *"\{0,1\}\([0-9a-f]*\).*/\1/p' "$HW/upstream.lock" | head -1)
SRC=${KERNEL_SRC:-${XDG_CACHE_HOME:-$HOME/.cache}/orchard/kernel-work/apple-16k-$(printf %.12s "$PIN")/source}
NAME=${1:-pvr-compute-test}
OUT=${OUT:-$HERE/../out/$NAME}
INC=$(mktemp -d)
mkdir -p "$INC/drm" "$INC/linux"
cp "$SRC/include/uapi/drm/pvr_drm.h" "$SRC/include/uapi/drm/drm.h" "$SRC/include/uapi/drm/drm_mode.h" "$INC/drm/"
cp "$SRC/include/uapi/linux/bits.h" "$SRC/include/uapi/linux/const.h" "$INC/linux/"
mkdir -p "$(dirname "$OUT")"
podman run --rm -v "$HERE:/src:ro" -v "$INC:/inc:ro" -v "$(dirname "$OUT"):/out" \
    localhost/orchard-hardware-kernel-toolchain:bookworm \
    aarch64-linux-gnu-gcc -static -O2 -Wall -D__user= -I/inc -o "/out/$(basename "$OUT")" "/src/$NAME.c" -lm
rm -rf "$INC"
ls -la "$OUT"
