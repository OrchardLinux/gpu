#!/bin/sh
# Pack the runtime image (Containerfile.runtime) into a compressed squashfs
# for the iPad's RAM: about 330 MB instead of 1.1 GB of files. gzip, as the
# kernel's squashfs reads only zlib. Needs mksquashfs (squashfs-tools 4.6+).
#
#   tools/a10/arch/build-root.sh      # -> ../out/arch/root.sqfs
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../out/arch
mkdir -p "$OUT"
cid=$(podman create localhost/orchard-gpu-alarm-runtime true)
trap 'podman rm "$cid" > /dev/null' EXIT
podman export "$cid" | mksquashfs - "$OUT/root.sqfs.part" -tar -comp gzip -noappend -quiet
mv "$OUT/root.sqfs.part" "$OUT/root.sqfs"
ls -la "$OUT/root.sqfs"
