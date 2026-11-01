#!/bin/sh
# Extract the A10 GPU firmware (apple/gfx-t8010.bin) from your own copy of
# the iPadOS 17.7.11 (21H461) kernelcache for iPad7,5/7,6 into this payload's
# rootfs (gitignored; the firmware is Apple's and is never committed):
#
#   ipsw download ipsw --device iPad7,5 --build 21H461 --kernel
#   tools/extract-firmware.sh PATH/TO/kernelcache.release.iPad7,5_6
#
# The firmware is the AGXFirmwareKextG9PRTBuddy kext's __TEXT,__const data
# in the decompressed kernelcache: 0x5b320 bytes at file offset 0xd41edf, an
# ARM32 image loaded at address 0 (a10/FIRST-LOOK.md). Other builds put it
# elsewhere: the checksum below refuses anything but the tested image.
set -eu
KC=${1:?usage: extract-firmware.sh KERNELCACHE}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../rootfs/lib/firmware/apple/gfx-t8010.bin
SHA256=104479454ada7f040e3c503d7ccc64a20ea46a60f2bbf906d3d5a3c6f6523c59

mkdir -p "$(dirname "$OUT")"
dd if="$KC" of="$OUT.part" bs=1 skip=$((0xd41edf)) count=$((0x5b320)) 2>/dev/null
got=$(shasum -a 256 "$OUT.part" | cut -d' ' -f1)
if [ "$got" != "$SHA256" ]; then
    rm -f "$OUT.part"
    echo "not the tested firmware (sha256 $got): is this the 21H461 iPad7,5/7,6 kernelcache, decompressed?" >&2
    exit 1
fi
mv "$OUT.part" "$OUT"
echo "$OUT"
