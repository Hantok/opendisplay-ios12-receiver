#!/bin/bash
# Build ODReceiver.app for jailbroken iOS 12 without Xcode: CLT clang + theos SDK + ldid.
set -euo pipefail
cd "$(dirname "$0")"
SDK="${SDK:-$(pwd)/sdk/iPhoneOS14.5.sdk}"
[ -d "$SDK" ] || { echo "No SDK at $SDK — run scripts/fetch-sdk.sh or set SDK=/path/to/iPhoneOS.sdk"; exit 1; }
MINOS="${MINOS:-12.0}"
APP=build/ODReceiver.app
rm -rf build && mkdir -p "$APP" build/Payload
clang -target arm64-apple-ios"$MINOS" -isysroot "$SDK" -fobjc-arc -O2 -Wall -Wno-unused-function \
  main.m -o "$APP/ODReceiver" \
  -framework UIKit -framework Foundation -framework AVFoundation -framework CoreMedia \
  -framework QuartzCore -framework CoreGraphics -framework VideoToolbox -framework CoreVideo
sed "s/<string>12.0<\/string>/<string>$MINOS<\/string>/" Info.plist > "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
cp icons/AppIcon60x60.png icons/AppIcon60x60@2x.png icons/AppIcon76x76~ipad.png icons/AppIcon76x76@2x~ipad.png "$APP/"
printf 'APPL????' > "$APP/PkgInfo"
ldid -Sentitlements.plist "$APP/ODReceiver"
cp -R "$APP" build/Payload/
(cd build && zip -qr ODReceiver.ipa Payload)
echo "built $APP and build/ODReceiver.ipa"
