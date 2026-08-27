#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
APP=${2:-}
DMG="$ROOT/dist/Miri-$VERSION.dmg"
SBOM="$ROOT/dist/Miri-$VERSION.spdx.json"

[[ -f "$DMG" ]] || { echo "usage: $0 <version> (DMG must already exist)" >&2; exit 2; }
command -v syft >/dev/null || { echo "syft is required to generate the SPDX SBOM" >&2; exit 2; }
# The notarized channel stages to .release, the community channel to .preview.
if [[ -z "$APP" ]]; then
  for candidate in "$ROOT/.release/Miri.app" "$ROOT/.preview/Miri.app"; do
    if [[ -d "$candidate" ]]; then APP="$candidate"; break; fi
  done
fi
[[ -d "$APP" ]] || { echo "no staged Miri.app found (pass one as \$2)" >&2; exit 2; }
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
