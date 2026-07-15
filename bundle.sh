#!/usr/bin/env bash
# Build Tack.app from the SwiftPM binary + Info.plist, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")"

PRODUCT=swift-executable   # SwiftPM product name
APP=Tack.app
EXE=Tack                   # executable name inside the bundle (matches CFBundleExecutable)

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$PRODUCT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "Built $APP — run:  open $APP"
echo "First launch prompts to control Finder; the 📌 lives in the menu bar."
