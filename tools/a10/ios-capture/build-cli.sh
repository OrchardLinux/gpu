#!/bin/sh
# The command-line capture tool (gpu-capture), ad-hoc (ldid) signed; no
# developer certificate. Push it to the iPad as /var/tmp/gpu-capture2.
set -eu
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" -Os -fobjc-arc \
    -framework Foundation -framework Metal capture.m -o build/gpu-capture
ldid -Sentitlements.plist build/gpu-capture
echo "built build/gpu-capture"
