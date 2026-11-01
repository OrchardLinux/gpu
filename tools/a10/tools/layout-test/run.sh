#!/bin/sh
# Builds pvr_apple_layout.c on the host and diffs it against the baseline-46
# golden images from tools/golden.sh.
#
# Historical: the driver's reference layout (gpu_root 0, hand-built page
# tables) that this compares left the driver when it went to orchard main
# (b5e3769). It works against kernel trees from before that.
#
#   ORCHARD=~/orchard tools/layout-test/run.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PIN=$(sed -n 's/^commit=//p' "${ORCHARD:?set ORCHARD to an orchard checkout}/kernel/upstream.lock" | cut -c1-12)
SRC=${KERNEL_SRC:-${XDG_CACHE_HOME:-$HOME/.cache}/orchard/kernel-work/apple-16k-$PIN/source}/drivers/gpu/drm/imagination
OUT=${TMPDIR:-/tmp}/pvr-apple-layout-test
mkdir -p "$OUT"
"$HERE/../golden.sh" "$OUT/golden" 46 >/dev/null
cc -Wall -I"$HERE" -I"$SRC" -o "$OUT/layout_test" "$HERE/layout_test.c" "$SRC/pvr_apple_layout.c"
"$OUT/layout_test" "$OUT/golden"
