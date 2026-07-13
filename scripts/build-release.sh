#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
ARCHIVE=${MIRI_PYTHON_STANDALONE_ARCHIVE:-}
EXPECTED_SHA=${MIRI_PYTHON_STANDALONE_SHA256:-}
DIST="$ROOT/dist"
STAGE="$ROOT/.release"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: MIRI_PYTHON_STANDALONE_ARCHIVE=... MIRI_PYTHON_STANDALONE_SHA256=... $0 <version>" >&2
  exit 2
fi
for tool in xcodegen xcodebuild swift uv shasum tar; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done
[[ -f "$ARCHIVE" ]] || { echo "MIRI_PYTHON_STANDALONE_ARCHIVE must name a downloaded archive" >&2; exit 2; }
MODEL_MANIFEST="$ROOT/Worker/models/model-manifest.json"
[[ -f "$MODEL_MANIFEST" ]] || { echo "release requires Worker/models/model-manifest.json with pinned artifacts" >&2; exit 2; }
uv run --project "$ROOT/Worker" --no-sync python "$ROOT/Worker/scripts/validate_manifest.py" "$MODEL_MANIFEST"
ACTUAL_SHA=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || { echo "standalone Python checksum mismatch" >&2; exit 2; }

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

tar -xf "$ARCHIVE" -C "$APP/Contents/Resources"
PYTHON="$APP/Contents/Resources/python/bin/python3"
if [[ ! -x "$PYTHON" ]]; then PYTHON="$APP/Contents/Resources/python/install/bin/python3"; fi
[[ -x "$PYTHON" ]] || { echo "archive must contain python/bin/python3 or python/install/bin/python3" >&2; exit 2; }
uv export --project "$ROOT/Worker" --extra inference --no-dev --no-emit-project --frozen \
  --output-file "$STAGE/worker-requirements.txt"
uv pip install --python "$PYTHON" --target "$APP/Contents/Resources/worker" \
  --require-hashes -r "$STAGE/worker-requirements.txt"
uv pip install --python "$PYTHON" --no-deps --target "$APP/Contents/Resources/worker" "$ROOT/Worker"
cp "$MODEL_MANIFEST" "$APP/Contents/Resources/model-manifest.json"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/docs/model-licenses.md" "$APP/Contents/Resources/MODEL-LICENSES.md"
cp "$ROOT/Worker/uv.lock" "$APP/Contents/Resources/worker/uv.lock"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
echo "Built unsigned release candidate at $APP"
echo "Run scripts/sign-and-notarize.sh before distribution."
