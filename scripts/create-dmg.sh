#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
APP=${2:-"$ROOT/.release/Miri.app"}
DMG="$ROOT/dist/Miri-$VERSION.dmg"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo "usage: $0 <version> [Miri.app]" >&2; exit 2; }
[[ -d "$APP" ]] || { echo "app not found: $APP" >&2; exit 2; }
/usr/bin/codesign --verify --deep --strict "$APP" || { echo "app must be signed before DMG creation" >&2; exit 2; }

rm -f "$DMG"
mkdir -p "$ROOT/dist"
/usr/bin/hdiutil create -volname Miri -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "Created $DMG"
