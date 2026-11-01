#!/bin/sh
# Everything the Mesa/Hyprland tests need on a freshly booted iPad (its /run
# is RAM): the Debian unstable chroot with the fork's Zink build
# (deploy-zink.sh), the test programs from ../out (build-vk-test.sh,
# build-gl-tests.sh), the fragment op tests, Hyprland's test config, the
# helper scripts and the effects demo. Files are pushed one by one: macOS
# tar writes sparse files the device's busybox tar cannot unpack.
#
#   mesa/setup-device.sh MESA_DIR    # from the orchard checkout, GPU driver loaded
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../out
MESA=$1

sh "$HERE/deploy-zink.sh" "$MESA"
for f in vk-tri kms-grab gbm-kms-test; do
    orchard push "$OUT/$f" "/run/sid/usr/local/bin/$f" > /dev/null
done
orchard push "$HERE/hypr-run.sh" /run/sid/usr/local/bin/hypr-run > /dev/null
orchard push "$HERE/vk-suite.sh" /run/sid/usr/local/bin/vk-suite > /dev/null
orchard exec -- mkdir -p /run/sid/root/.config/hypr /run/sid/root/fsops
orchard push "$HERE/hyprland-test.lua" /run/sid/root/.config/hypr/hyprland.lua > /dev/null
for f in "$OUT"/fsops/*; do
    orchard push "$f" "/run/sid/root/fsops/$(basename "$f")" > /dev/null
done
# the demos (hypr-demo.sh): configs, window contents and wallpapers (the
# Jade Horse one downloaded once into ../out)
orchard push "$HERE/hyprland-demo.lua" /run/sid/root/demo.lua > /dev/null
orchard push "$HERE/hyprland-jade.lua" /run/sid/root/jade.lua > /dev/null
orchard push "$HERE/foot-jade.ini" /run/sid/root/foot-jade.ini > /dev/null
orchard push "$HERE/demo-term.sh" /run/sid/root/demo-term.sh > /dev/null
python3 "$HERE/demo-wallpaper.py" "$OUT/demo-wallpaper.png"
[ -f "$OUT/jade-wallpaper.png" ] || sh "$HERE/jade-wallpaper.sh" "$OUT/jade-wallpaper.png"
orchard push "$OUT/demo-wallpaper.png" /run/sid/root/wall-demo.png > /dev/null
orchard push "$OUT/jade-wallpaper.png" /run/sid/root/wall-jade.png > /dev/null
for f in hypr-once.sh hypr-start.sh hypr-demo.sh hypr-bench.sh hctl.sh gpu-reload.sh fsone.sh; do
    orchard push "$HERE/$f" "/run/$f" > /dev/null
done
orchard exec -- sh -c 'chmod +x /run/sid/usr/local/bin/* /run/*.sh'
echo "device ready: vk-suite, /run/fsone.sh, /run/hypr-once.sh SECONDS, /run/hypr-demo.sh SECONDS [demo|jade], /run/hypr-bench.sh [moves N|glide|time N|profile]"
