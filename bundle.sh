#!/usr/bin/env bash
# Build Tack.app from the SwiftPM binary + Info.plist.
# Signed with a keychain identity so TCC (Accessibility, Automation) keeps the
# grant across rebuilds — ad-hoc signing gets re-prompted every time.
# ponytail: first codesigning identity in the keychain; set SIGN_ID to override.
set -euo pipefail
cd "$(dirname "$0")"

PRODUCT=swift-executable   # SwiftPM product name
APP=Tack.app
EXE=Tack                   # executable name inside the bundle (matches CFBundleExecutable)

# BUILD_FLAGS="--arch arm64 --arch x86_64" builds universal (CI does; local stays host-only fast)
swift build -c release ${BUILD_FLAGS:-}
BIN="$(swift build -c release ${BUILD_FLAGS:-} --show-bin-path)/$PRODUCT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"
# icon.png is the bare artwork at any size; macOS wants it 824x824 centred in a
# 1024 canvas, or the icon reads bigger than every neighbour in the Dock.
# `sips -c` grows the canvas with transparent padding; -z then downscales per slot.
ICONSET="$(mktemp -d)"
mkdir -p "$ICONSET/AppIcon.iconset"
sips -Z 824 public/icon.png --out "$ICONSET/icon1024.png" >/dev/null
sips -c 1024 1024 "$ICONSET/icon1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICONSET/icon1024.png" --out "$ICONSET/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$ICONSET/icon1024.png" --out "$ICONSET/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk 'NR==1 {print $2}')}"
[ -n "$SIGN_ID" ] || { echo "No codesigning identity in keychain; see README." >&2; exit 1; }
codesign --force --sign "$SIGN_ID" "$APP"

# ponytail: rm before cp — cp -R into an existing .app nests it instead of replacing.
rm -rf "/Applications/$APP"
cp -R "$APP" /Applications/

echo "Installed /Applications/$APP — run:  open -a $EXE"
echo "First launch prompts to control Finder; the 📌 lives in the menu bar."
