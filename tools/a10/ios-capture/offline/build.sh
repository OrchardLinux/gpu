#!/bin/sh
# Offline applegpu_g9p (A10) compile. Needs: xcodebuild -downloadComponent MetalToolchain
set -eu
cd "$(dirname "$0")"
xcrun metal -target air64-apple-ios17.0 -c k.metal -o k.air
xcrun metallib k.air -o k.metallib
xcrun metal-tt -arch applegpu_g9p -target air64-apple-ios17.0 k.metallib p.mtlp-json -o k.g9p.bin
rm -f k.air
