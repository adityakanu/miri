#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
APP=${2:-}
DMG="$ROOT/dist/Miri-$VERSION.dmg"
SBOM="$ROOT/dist/Miri-$VERSION.spdx.json"

[[ -f "$DMG" ]] || { echo "usage: $0 <version> (DMG must already exist)" >&2; exit 2; }
# The community channel stages to .preview, the notarized channel to .release.
# Community is the shipping channel, so it wins when both are staged; either
# channel can override by passing the bundle explicitly as $2.
if [[ -z "$APP" ]]; then
  for candidate in "$ROOT/.preview/Miri.app" "$ROOT/.release/Miri.app"; do
    if [[ -d "$candidate" ]]; then APP="$candidate"; break; fi
  done
fi
[[ -d "$APP" ]] || {
  echo "no staged Miri.app found at $ROOT/.preview or $ROOT/.release (pass one as \$2)" >&2
  exit 2
}

# Fail closed if the staged bundle is not the version being published.
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ "$APP_VERSION" == "$VERSION" ]] || {
  echo "staged $APP reports version '$APP_VERSION', expected '$VERSION'" >&2
  exit 1
}

# Checked after the version gate so a mismatched bundle fails for the right
# reason on machines that do have syft.
command -v syft >/dev/null || { echo "syft is required to generate the SPDX SBOM" >&2; exit 2; }

syft "dir:$APP" -o "spdx-json=$SBOM"
(
  cd "$ROOT/dist"
  files=("Miri-$VERSION.dmg")
  if [[ -f "Miri-$VERSION.zip" ]]; then files+=("Miri-$VERSION.zip"); fi
  files+=("Miri-$VERSION.spdx.json")
  shasum -a 256 "${files[@]}" > "Miri-$VERSION.sha256"
)

DMG_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$DMG_SHA/g" \
  "$ROOT/Casks/miri.rb.template" > "$ROOT/dist/miri.rb"
echo "Wrote checksums, SPDX SBOM, and release Cask under $ROOT/dist"
