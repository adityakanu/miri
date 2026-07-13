#!/bin/bash
set -euo pipefail

# Build an unsigned, self-contained GitHub-preview artifact. This is explicitly
# not a notarized release and must never be submitted to the official Homebrew
# Cask repository.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
PYTHON=${2:-}
DIST="$ROOT/dist"
STAGE="$ROOT/.preview"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "usage: $0 <version> <standalone-python>" >&2
  exit 2
}
[[ -x "$PYTHON" ]] || { echo "python is not executable: $PYTHON" >&2; exit 2; }
for tool in xcodegen xcodebuild swift uv ditto hdiutil shasum; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done

rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
cd "$ROOT"
xcodegen generate
swift build -c release --product miri
swift build -c release --product miri-mcp
xcodebuild -project Miri.xcodeproj -scheme Miri -configuration Release \
  -derivedDataPath "$STAGE/DerivedData" CODE_SIGNING_ALLOWED=NO build

APP_SOURCE="$STAGE/DerivedData/Build/Products/Release/Miri.app"
APP="$STAGE/Miri.app"
[[ -d "$APP_SOURCE" ]] || { echo "Xcode did not produce Miri.app" >&2; exit 1; }
ditto "$APP_SOURCE" "$APP"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/worker"
install -m 0755 "$ROOT/.build/release/miri" "$APP/Contents/Helpers/miri"
install -m 0755 "$ROOT/.build/release/miri-mcp" "$APP/Contents/Helpers/miri-mcp"
install -m 0755 "$ROOT/scripts/miri-worker-launcher" "$APP/Contents/Helpers/miri-worker"

PYTHON_ROOT=$("$PYTHON" -c 'import sys; print(sys.prefix)')
[[ -x "$PYTHON_ROOT/bin/python3" ]] || { echo "python prefix is not relocatable: $PYTHON_ROOT" >&2; exit 2; }
ditto "$PYTHON_ROOT" "$APP/Contents/Resources/python"
APP_PYTHON="$APP/Contents/Resources/python/bin/python3"

uv export --project "$ROOT/Worker" --extra inference --no-dev --no-emit-project --frozen \
  --output-file "$STAGE/worker-requirements.txt"
uv pip install --python "$APP_PYTHON" --target "$APP/Contents/Resources/worker" \
  --require-hashes -r "$STAGE/worker-requirements.txt"
uv pip install --python "$APP_PYTHON" --no-deps --target "$APP/Contents/Resources/worker" "$ROOT/Worker"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/docs/model-licenses.md" "$APP/Contents/Resources/MODEL-LICENSES.md"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
DMG="$DIST/Miri-$VERSION-preview.dmg"
ZIP="$DIST/Miri-$VERSION-preview.zip"
rm -f "$DMG" "$ZIP"
/usr/bin/hdiutil create -volname "Miri Preview" -srcfolder "$APP" -ov -format UDZO "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > "Miri-$VERSION-preview.sha256")
echo "Created unsigned preview artifacts under $DIST"
