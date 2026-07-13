#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
DMG="$ROOT/dist/Miri-$VERSION.dmg"
SBOM="$ROOT/dist/Miri-$VERSION.spdx.json"

[[ -f "$DMG" ]] || { echo "usage: $0 <version> (DMG must already exist)" >&2; exit 2; }
command -v syft >/dev/null || { echo "syft is required to generate the SPDX SBOM" >&2; exit 2; }
syft "dir:$ROOT/.release/Miri.app" -o "spdx-json=$SBOM"
(cd "$ROOT/dist" && shasum -a 256 "Miri-$VERSION.dmg" "Miri-$VERSION.spdx.json" > "Miri-$VERSION.sha256")

DMG_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$DMG_SHA/g" \
  "$ROOT/Casks/miri.rb.template" > "$ROOT/dist/miri.rb"
echo "Wrote checksums, SPDX SBOM, and release Cask under $ROOT/dist"
