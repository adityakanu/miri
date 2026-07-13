#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DMG=${1:-}
PROFILE=${APPLE_NOTARY_PROFILE:-}

[[ -f "$DMG" ]] || { echo "usage: $0 dist/Miri-<version>.dmg" >&2; exit 2; }
[[ -n "$PROFILE" ]] || { echo "APPLE_NOTARY_PROFILE is required (create with xcrun notarytool store-credentials)" >&2; exit 2; }

/usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$DMG"
/usr/bin/xcrun stapler validate "$DMG"
/usr/sbin/spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Notarization accepted and ticket stapled: $DMG"
