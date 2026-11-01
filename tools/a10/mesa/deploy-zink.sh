#!/bin/sh
# Install the fork's Zink build (Vulkan driver, Zink, EGL, GBM: build dir
# build-zink, Debian unstable) into a Debian unstable chroot in the iPad's RAM
# (/run/sid, from Containerfile.runtime-sid, created once per boot; it
# replaces the first, trixie chroot, as /run holds about 970 MB) and
# run a command there:  mesa/deploy-zink.sh MESA_DIR [COMMAND...]
# Run inside the orchard checkout (uses orchard push/exec).
set -eu
MESA=$1; shift
TMP=$(mktemp -d)
if ! orchard exec -- test -d /run/sid/usr; then
    orchard exec -- sh -c 'for d in dev proc sys; do umount /run/deb/$d 2>/dev/null; done; rm -rf /run/deb'
    cid=$(podman create localhost/orchard-mesa-g9p-runtime:sid true)
    podman export "$cid" | gzip -1 > "$TMP/rt.tar.gz"
    podman rm "$cid" > /dev/null
    orchard push "$TMP/rt.tar.gz" /run/rt.tar.gz > /dev/null
    orchard exec -- sh -c 'mkdir -p /run/sid && zcat /run/rt.tar.gz | tar xf - -C /run/sid &&
        rm /run/rt.tar.gz && for d in dev proc sys; do mount --bind /$d /run/sid/$d; done &&
        mount --bind /dev/pts /run/sid/dev/pts &&
        mount -t tmpfs tmpfs /run/sid/tmp && mkdir -p /run/sid/run/user/0 && chmod 700 /run/sid/run/user/0'
fi
podman run --rm -v "$MESA:/mesa" -v "$TMP:/out" localhost/orchard-mesa-g9p:sid sh -c '
    DESTDIR=/out/stage meson install -C /mesa/build-zink --quiet --no-rebuild >/dev/null &&
    find /out/stage -name "*.so*" -type f -exec strip --strip-unneeded {} + &&
    rm -rf /out/stage/usr/include /out/stage/usr/lib/aarch64-linux-gnu/pkgconfig &&
    tar -C /out/stage -czf /out/mesa.tar.gz .'
orchard push "$TMP/mesa.tar.gz" /run/mesa.tar.gz > /dev/null
orchard exec -- sh -c 'zcat /run/mesa.tar.gz | tar xf - -C /run/sid && rm /run/mesa.tar.gz'
rm -rf "$TMP"
[ $# -eq 0 ] || orchard exec -- chroot /run/sid sh -c "$*"
