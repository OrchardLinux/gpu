#!/bin/sh
# Edit the A10 GPU kernel patches outside the shared kernel tree, which refuses
# hand edits. Builds a small git repository holding only the files the patches
# (and planned edits) touch: pristine upstream, then the current apple-16k
# series, then our two patch layers as commits. Edit, amend, and export.
#
#   ORCHARD=~/orchard tools/patch-repo.sh init REPO [EXTRA_FILE...]  # build it
#   ORCHARD=~/orchard tools/patch-repo.sh export REPO  # write the layers back
#
# ORCHARD is the orchard checkout whose kernel/ layers are edited.
set -eu
HW=$(cd "${ORCHARD:?set ORCHARD to an orchard checkout}/kernel" && pwd)
PIN=$(sed -n 's/^commit *= *"\{0,1\}\([0-9a-f]*\).*/\1/p' "$HW/upstream.lock" | head -1)
SRC=${KERNEL_SRC:-${XDG_CACHE_HOME:-$HOME/.cache}/orchard/kernel-work/apple-16k-$(printf %.12s "$PIN")/source}
LAYERS="patches/devices/t8010/0011-arm64-dts-apple-t8010-Describe-the-GPU.patch
patches/drivers/gpu/0001-drm-imagination-Support-the-Apple-A10-T8010-GPU.patch"
cmd=$1 repo=$2
shift 2

case $cmd in
init)
    files=$(for l in $LAYERS; do sed -n 's|^+++ b/||p' "$HW/$l"; done; printf '%s\n' "$@")
    rm -rf "$repo" && mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.name "$(git -C "$HW" config user.name)"
    git -C "$repo" config user.email "$(git -C "$HW" config user.email)"
    inc=""
    for f in $(printf '%s\n' "$files" | sort -u); do
        if git -C "$SRC" cat-file -e "HEAD:$f" 2>/dev/null; then
            mkdir -p "$repo/$(dirname "$f")"
            git -C "$SRC" show "HEAD:$f" > "$repo/$f"
        fi
        inc="$inc --include=$f"
    done
    git -C "$repo" add -A && git -C "$repo" commit -qm pristine
    for d in $(grep -v '^#' "$HW/series/apple-16k"); do
        for p in $(cd "$HW" && find "$d" -name '*.patch' | sort); do
            case $LAYERS in *"$p"*) continue ;; esac
            # shellcheck disable=SC2086
            git -C "$repo" apply $inc "$HW/$p"
        done
    done
    git -C "$repo" add -A && git -C "$repo" commit -qm series
    for l in $LAYERS; do git -C "$repo" am -q "$HW/$l"; done
    git -C "$repo" log --oneline -2
    ;;
export)
    out=$(mktemp -d)
    git -C "$repo" format-patch -q --zero-commit HEAD~2 -o "$out"
    set -- $LAYERS
    for f in "$out"/0001-* "$out"/0002-*; do cp "$f" "$HW/$1"; shift; done
    rm -rf "$out"
    git -C "$HW" status --short -- patches
    ;;
*) echo "usage: $0 init|export REPO [FILE...]" >&2; exit 2 ;;
esac
