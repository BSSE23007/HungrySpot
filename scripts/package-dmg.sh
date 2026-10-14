#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then echo "DMG creation requires macOS." >&2; exit 1; fi
MODE="${1:-}"
if [[ "$MODE" != "--unsigned" && "$MODE" != "--signed" ]]; then
  echo "Usage: bash scripts/package-dmg.sh --unsigned|--signed" >&2
  echo "Signed mode requires DEVELOPER_ID and NOTARY_PROFILE." >&2
  exit 1
fi
if [[ "$MODE" == "--signed" ]]; then
  : "${DEVELOPER_ID:?Set your Developer ID Application signing identity}"
  : "${NOTARY_PROFILE:?Set a notarytool Keychain profile; never embed a password}"
fi
bash scripts/build-macos.sh
mkdir -p dist
STAGING="$(mktemp -d "$PWD/dist/staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/The Hungry Spot.app"
ditto "build/The Hungry Spot.app" "$APP"
if [[ "$MODE" == "--signed" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi
ln -s /Applications "$STAGING/Applications"
DMG="$PWD/dist/TheHungrySpot-1.0.0-$(date +%Y%m%d-%H%M%S).dmg"
hdiutil create -volname "The Hungry Spot" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
if [[ "$MODE" == "--signed" ]]; then
  codesign --timestamp --sign "$DEVELOPER_ID" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi
echo "Created: $DMG"
