#!/bin/bash
set -euo pipefail

# Build an ad-hoc signed, self-contained GitHub community artifact. This is
# not a notarized release and must never be submitted to the official Homebrew
# Cask repository.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
DIST="$ROOT/dist"
STAGE="$ROOT/.preview"
DMG_ROOT="$STAGE/dmg-root"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "usage: $0 <version>" >&2
  exit 2
}
for tool in xcodegen xcodebuild swift ditto hdiutil shasum codesign; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done

rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
cd "$ROOT"
xcodegen generate
swift build -c release --product miri
swift build -c release --product miri-mcp
xcodebuild -project Miri.xcodeproj -scheme MiriApp -configuration Release \
  -derivedDataPath "$STAGE/DerivedData" CODE_SIGNING_ALLOWED=NO build

APP_SOURCE="$STAGE/DerivedData/Build/Products/Release/Miri.app"
APP="$STAGE/Miri.app"
[[ -d "$APP_SOURCE" ]] || { echo "Xcode did not produce Miri.app" >&2; exit 1; }
ditto "$APP_SOURCE" "$APP"
mkdir -p "$APP/Contents/Helpers"
install -m 0755 "$ROOT/.build/release/miri" "$APP/Contents/Helpers/miri"
install -m 0755 "$ROOT/.build/release/miri-mcp" "$APP/Contents/Helpers/miri-mcp"

# Speech runs on CoreML inside the app. No Python runtime, no worker helper,
# and no model weights are embedded: Parakeet and PocketTTS models are fetched
# on first use after the user consents.
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/docs/model-licenses.md" "$APP/Contents/Resources/MODEL-LICENSES.md"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
# Adding the CLI helpers invalidates Xcode's initial signature.
# Re-sign the completed bundle ad-hoc: this costs nothing and is required for
# executable code on Apple Silicon, but it is not Developer ID notarization.
codesign --force --deep --sign - --timestamp=none \
  --entitlements "$ROOT/App/Miri.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
DMG="$DIST/Miri-$VERSION.dmg"
ZIP="$DIST/Miri-$VERSION.zip"
rm -f "$DMG" "$ZIP"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Miri.app"
ln -s /Applications "$DMG_ROOT/Applications"
/usr/bin/hdiutil create -volname "Miri $VERSION" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > "Miri-$VERSION.sha256")
echo "Created ad-hoc signed community artifacts under $DIST"
