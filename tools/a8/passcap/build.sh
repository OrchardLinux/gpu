#!/bin/sh
# SPDX-License-Identifier: MIT
# Build a8-passcap and passcap.metallib for an A8 device on iOS 12 (arm64, Metal 2.1).
# Needs macOS with Xcode (iphoneos SDK) and ldid. Output: $OUT (default ./out).
set -eu
cd "$(dirname "$0")"
OUT="${OUT:-$PWD/out}"
mkdir -p "$OUT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "[*] SDK $SDK"

xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=12.0 -isysroot "$SDK" \
	-O2 -Wall -Wextra -Werror -fobjc-arc \
	-framework Foundation -framework Metal \
	a8-passcap.m -o "$OUT/a8-passcap"

# iOS 12 accepts Metal 2.1 at most; pin both the language and the deployment target.
xcrun -sdk iphoneos metal -std=ios-metal2.1 -mios-version-min=12.0 -c passcap.metal -o "$OUT/passcap.air"
xcrun -sdk iphoneos metallib "$OUT/passcap.air" -o "$OUT/passcap.metallib"
rm -f "$OUT/passcap.air"

LDID="${LDID:-ldid}"
"$LDID" -Smetal.entitlements.plist "$OUT/a8-passcap"

for f in a8-passcap passcap.metallib; do
	printf '[*] %s %s bytes sha256=%s\n' "$OUT/$f" "$(wc -c <"$OUT/$f" | tr -d ' ')" \
		"$(shasum -a 256 "$OUT/$f" | cut -d' ' -f1)"
done
