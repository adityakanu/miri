#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-"$ROOT/.release/Miri.app"}
IDENTITY=${APPLE_SIGN_IDENTITY:-}

[[ -d "$APP" ]] || { echo "usage: $0 [path/to/Miri.app]" >&2; exit 2; }
[[ -n "$IDENTITY" ]] || { echo "APPLE_SIGN_IDENTITY is required; refusing an ad-hoc release signature" >&2; exit 2; }

# Sign nested Mach-O executables before the outer bundle. The standalone runtime
# may contain additional dylibs, so sign every Mach-O file discovered by `file`.
while IFS= read -r -d '' candidate; do
  if /usr/bin/file "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign --force --timestamp --options runtime --sign "$IDENTITY" "$candidate"
  fi
done < <(/usr/bin/find "$APP/Contents" -type f -print0)
/usr/bin/codesign --force --timestamp --options runtime \
  --entitlements "$ROOT/App/Miri.entitlements" --sign "$IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "Signed $APP. Create the DMG, then submit it with scripts/notarize.sh."
