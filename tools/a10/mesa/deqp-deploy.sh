#!/bin/sh
# Copies dEQP (mesa/build-deqp.sh) and the GPU health probe (arch/build-vk-tests.sh)
# to the installed Omarchy A, for mesa/deqp-run.py. Needs the A10 overlay
# (arch/apply-installed.sh). Run inside the orchard checkout:
#   mesa/deqp-deploy.sh OUT_DIR [gles2 gles3 gles31 glcts]    # default: all
# The binaries are built on Debian unstable; Arch Linux ARM's glibc and
# libstdc++ run them. Packed in the build image: macOS tar writes sparse files.
set -eu
OUT=$(cd "$1" && pwd); shift
[ $# -gt 0 ] || set -- gles2 gles3 gles31 glcts
DEST=${DEQP_DEST:-/home/tablet/deqp}
TMP=$(mktemp -d)
podman run --rm -v "$OUT/deqp:/deqp:ro" -v "$TMP:/tmp/o" localhost/orchard-deqp:sid \
    tar -C /deqp -czf /tmp/o/deqp.tar.gz "$@"
orchard exec -- mkdir -p "$DEST"
orchard push "$TMP/deqp.tar.gz" /tmp/deqp.tar.gz > /dev/null
orchard push "$OUT/arch/vk-tri" "$DEST/vk-tri" > /dev/null
orchard exec -- sh -c "chmod +x '$DEST/vk-tri' && tar xzf /tmp/deqp.tar.gz -C '$DEST' && rm /tmp/deqp.tar.gz; df -h '$DEST' | tail -1"
rm -rf "$TMP"
