#!/bin/bash
# Runs inside the orchard-deqp container (see build-deqp.sh). Each step leaves
# a marker in the tmpfs /w, so a rerun in the same container continues.
set -euo pipefail
TAG=opengl-es-cts-3.2.14.1
# Mesa CI's GLES backports and patches (.gitlab-ci/container/build-deqp.sh)
BACKPORTS="b5ed8718f19492781f8e9be3eb9d3346e961efa9
6368ee8503dd9ca46eabfa2df293075d9034a214
e39758bc9262f8593cf0fddf1364179c1fedf756
fe92180156795a641b684722a199bdb64c69bf2a
bf307df9e5c6c27499c2c799409d17554d39cafc
5d392ccf4fa09d38d06ca66875a2aaac4fde2b11
758d0f50723d3f1ce1dd8141fb2b5f8698c54bd1
527f723b666547c34b45522ef25a116107b5c540
a3918c1dd4f409c28b3a85cc89e9875ff2ca864c
3e98747abfc47130a9f854ab1130b86d494de260"
PATCHES="build-deqp-gl_Build-Don-t-build-Vulkan-utilities-for-GL-builds.patch
build-deqp-Fix-gles2-internalformat-texture-float-tests.patch"
JOBS=${JOBS:-6}
SRC=/w/src
BLD=/w/bld

if [ ! -e /w/.cloned ]; then
    rm -rf "$SRC"
    git clone --depth 1 -b "$TAG" https://github.com/KhronosGroup/VK-GL-CTS.git "$SRC"
    git -C "$SRC" config user.email deqp@localhost
    git -C "$SRC" config user.name deqp
    for c in $BACKPORTS; do
        curl -fsSL --retry 3 "https://github.com/KhronosGroup/VK-GL-CTS/commit/$c.patch" | git -C "$SRC" am -q -
    done
    for p in $PATCHES; do
        git -C "$SRC" am -q < "/mesa-patches/$p"
    done
    touch /w/.cloned
fi

if [ ! -e /w/.fetched ]; then
    # fetch_sources.py clones every dependency with its full history (about
    # 2 GB, more than this tmpfs should hold): same pinned revisions, depth 1.
    # CMake configures the video repositories even for these targets.
    cd "$SRC/external"
    python3 - <<'P'
import argparse, os, subprocess, sys
sys.argv = ["fetch_sources.py"]
sys.path.insert(0, os.getcwd())
import fetch_sources as f
f.args = argparse.Namespace(insecure=False, protocol="https", force=False)  # its globals
skip = {"vulkan-validationlayers"}
for p in f.PACKAGES:
    if p.baseDir in skip:
        continue
    if not isinstance(p, f.GitRepo):
        f.pkg = p  # isArchiveUpToDate() reads this global of its script
        p.update("https")
        continue
    d = os.path.join(f.EXTERNAL_DIR, p.baseDir, p.extractDir)
    subprocess.check_call(["git", "init", "-q", d])
    subprocess.check_call(["git", "-C", d, "fetch", "-q", "--depth", "1", p.httpsUrl, p.revision])
    subprocess.check_call(["git", "-C", d, "checkout", "-q", "FETCH_HEAD"])
    if p.patch:
        subprocess.check_call(["git", "-C", d, "apply", os.path.join(f.EXTERNAL_DIR, p.patch)])
    print("fetched", p.baseDir, p.revision, flush=True)
P
    touch /w/.fetched
fi
df -h /w | tail -1

TARGETS=(deqp-gles2 deqp-gles3 deqp-gles31 glcts)
IFS=';' SBT="${TARGETS[*]}"; unset IFS
cmake -S "$SRC" -B "$BLD" -G Ninja -DDEQP_TARGET=surfaceless \
    -DCMAKE_BUILD_TYPE=Release -DSELECTED_BUILD_TARGETS="$SBT"
nice -n 10 ninja -C "$BLD" -j"$JOBS" "${TARGETS[@]}"
df -h /w | tail -1

# Only what the device runs: stripped binaries, their data, the case lists
O=/out/deqp
rm -rf "$O"; mkdir -p "$O/mustpass"
for m in gles2 gles3 gles31; do
    mkdir -p "$O/$m"
    cp -L "$BLD/modules/$m/deqp-$m" "$O/$m/"
    strip "$O/$m/deqp-$m"
    cp -aL "$BLD/modules/$m/$m" "$O/$m/" 2>/dev/null || true
done
mkdir -p "$O/glcts"
cp -L "$BLD/external/openglcts/modules/glcts" "$O/glcts/"
strip "$O/glcts/glcts"
cp -aL "$BLD/external/openglcts/modules/gl_cts" "$O/glcts/" 2>/dev/null || true
M="$SRC/external/openglcts/data/gl_cts/data/mustpass"
cp "$M"/gles/aosp_mustpass/main/*.txt "$O/mustpass/"
cp "$M"/gles/khronos_mustpass/main/*-main.txt "$O/mustpass/"
rm -rf "$O"/glcts/gl_cts/data/mustpass 2>/dev/null || true
git -C "$SRC" log --format='%h %s' > "$O/VERSION"
echo "$TAG" >> "$O/VERSION"
du -sh "$O" "$O"/*

# Smoke test on llvmpipe: do the binaries find a GL context and their data?
export EGL_PLATFORM=surfaceless LIBGL_ALWAYS_SOFTWARE=1
ARGS="--deqp-surface-width=256 --deqp-surface-height=256 --deqp-surface-type=pbuffer --deqp-gl-config-name=rgba8888d24s8ms0 --deqp-visibility=hidden --deqp-log-images=disable --deqp-log-shader-sources=disable --deqp-log-filename=/tmp/smoke.qpa"
for s in "gles2 dEQP-GLES2.info.*" "gles3 dEQP-GLES3.functional.texture.format.sized.2d.rgba8_npot" "gles31 dEQP-GLES31.functional.compute.basic.empty"; do
    set -- $s
    ( cd "$O/$1" && timeout -k 5 120 "./deqp-$1" $ARGS "--deqp-case=$2" | tail -8 )
done
