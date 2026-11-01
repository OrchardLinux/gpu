#!/bin/sh
# Ad-hoc (ldid) signed GPUCapture.app; no developer certificate.
set -eu
cd "$(dirname "$0")"
APP=build/GPUCapture.app
rm -rf "$APP" && mkdir -p "$APP"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" -Os -fobjc-arc \
    -framework Foundation -framework Metal -framework UIKit app.m -o "$APP/GPUCapture"
plutil -create xml1 "$APP/Info.plist"
for kv in CFBundleIdentifier=dev.orchard.gpu-capture-adhoc CFBundleExecutable=GPUCapture \
          CFBundleName=GPUCapture CFBundleDisplayName="GPU Capture" CFBundlePackageType=APPL \
          CFBundleVersion=1 CFBundleShortVersionString=1.0 MinimumOSVersion=16.0; do
    plutil -insert "${kv%%=*}" -string "${kv#*=}" "$APP/Info.plist"
done
plutil -insert UIDeviceFamily -json '[1,2]' "$APP/Info.plist"
plutil -insert UILaunchScreen -json '{}' "$APP/Info.plist"
plutil -insert UIRequiresFullScreen -bool YES "$APP/Info.plist"
ldid -Sentitlements.plist "$APP/GPUCapture"
echo "built $APP"
