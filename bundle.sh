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
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk 'NR==1 {print $2}')}"
[ -n "$SIGN_ID" ] || { echo "No codesigning identity in keychain; see README." >&2; exit 1; }
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP — run:  open $APP"
echo "First launch prompts to control Finder; the 📌 lives in the menu bar."
