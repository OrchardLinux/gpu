#!/bin/sh
# Builds the GL/KMS tools gbm-kms-test and kms-grab (arm64, against the
# Debian unstable userland of the device chroot /run/sid) in the sid Mesa
# build container: mesa/build-gl-tests.sh OUT_DIR
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
podman run --rm -v "$HERE:/src:ro" -v "$OUT:/out" localhost/orchard-mesa-g9p:sid sh -c '
    gcc -O2 -Wall -o /out/gbm-kms-test /src/gbm-kms-test.c $(pkg-config --cflags libdrm) \
        -lgbm -lEGL -lGLESv2 -ldrm -lm &&
    gcc -O2 -Wall -o /out/kms-grab /src/kms-grab.c $(pkg-config --cflags --libs libdrm)'
ls -la "$OUT/gbm-kms-test" "$OUT/kms-grab"
