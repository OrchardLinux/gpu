#!/bin/sh
# Builds dEQP (GLES 2, 3, 3.1 and glcts for the KHR tests, the release and
# patches Mesa CI uses) for the device chroot /run/sid:
#   mesa/build-deqp.sh MESA_DIR OUT_DIR    # installs into OUT_DIR/deqp
# Source and objects stay in a tmpfs inside the container, because the Mac's
# disk has no room for them; only the result lands in OUT_DIR. A failed run
# keeps the container, and rerunning continues in it. KEEP=1 keeps it after
# success as well.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
MESA=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
NAME=orchard-deqp-build
podman image exists localhost/orchard-deqp:sid ||
    podman build -f "$HERE/Containerfile.deqp" -t orchard-deqp:sid "$HERE"
podman container exists "$NAME" ||
    podman run -d --name "$NAME" --tmpfs /w:rw,exec,size=10g \
        -v "$HERE:/tools:ro" -v "$MESA/.gitlab-ci/container/patches:/mesa-patches:ro" -v "$OUT:/out" \
        localhost/orchard-deqp:sid sleep 86400 > /dev/null
podman exec -e "JOBS=${JOBS:-6}" "$NAME" bash /tools/build-deqp-inner.sh
[ -n "${KEEP:-}" ] || podman rm -f "$NAME" > /dev/null
