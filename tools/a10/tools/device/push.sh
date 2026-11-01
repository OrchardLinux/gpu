#!/bin/sh
# Copy the built tools into the device chroot's /root (after
# mesa/setup-device.sh; /run is RAM, so again after every boot). They need
# /dev/mem and run as: orchard exec -- chroot /run/sid /root/gpuperf
set -eu
OUT=$(cd "$(dirname "$0")/../../out/device" && pwd)
for f in "$OUT"/*; do
    orchard push "$f" "/run/sid/root/$(basename "$f")" > /dev/null
done
orchard exec -- sh -c 'chmod +x /run/sid/root/*'
