#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
DIST="$ROOT/dist"
STAGE="$ROOT/.release"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi
for tool in xcodegen xcodebuild swift shasum; do
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

# Speech runs on CoreML inside the app: no Python runtime and no embedded
# weights. Models are fetched on first use after the user consents.
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/docs/model-licenses.md" "$APP/Contents/Resources/MODEL-LICENSES.md"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
echo "Built unsigned release candidate at $APP"
echo "Run scripts/sign-and-notarize.sh before distribution."
