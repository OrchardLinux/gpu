#!/bin/sh
# Build the device-side bring-up tools (static arm64 binaries) in the Mesa
# build container (mesa/Containerfile) into ../../out/device:
#   tools/device/build.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../../out/device
mkdir -p "$OUT"
podman run --rm -v "$HERE:/src:ro" -v "$OUT:/out" localhost/orchard-mesa-g9p:trixie sh -c '
    for c in /src/*.c; do
        gcc -O2 -Wall -static -o /out/$(basename "$c" .c) "$c" || exit 1
    done'
ls "$OUT"
