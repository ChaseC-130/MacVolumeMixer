#!/bin/bash
# Package build/AppVolumeMixer.app into a drag-to-Applications .dmg.
# Optionally notarize + staple when NOTARY_PROFILE is set to a stored
# `xcrun notarytool store-credentials` profile name.
#
#   ./package_dmg.sh                         # build DMG only
#   NOTARY_PROFILE=AVM-notary ./package_dmg.sh   # build + notarize + staple
set -euo pipefail

APP_NAME="AppVolumeMixer"
VOLNAME="App Volume Mixer"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/$APP_NAME.app"

[[ -d "$APP" ]] || { echo "Build the app first: ./build.sh"; exit 1; }

VER="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/${APP_NAME}-${VER}.dmg"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"

echo "==> Building $DMG"
rm -f "$DMG"
create-dmg \
  --volname "$VOLNAME" \
  --window-pos 200 120 \
  --window-size 560 380 \
  --icon-size 110 \
  --icon "${APP_NAME}.app" 150 195 \
  --app-drop-link 410 195 \
  --no-internet-enable \
  "$DMG" \
  "$STAGING" || true   # create-dmg exits non-zero if the AppleScript layout step
                       # is blocked; the DMG is still produced and usable.
rm -rf "$STAGING"
[[ -f "$DMG" ]] || { echo "DMG was not created"; exit 1; }

# Sign the container itself when a Developer ID identity is available. The app
# inside is already signed by build.sh, but Gatekeeper's primary-signature check
# also expects a signed DMG for a warning-free downloaded release.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGN="$SIGN_IDENTITY"
else
  SIGN="$(security find-identity -p codesigning -v 2>/dev/null | awk '/Developer ID Application/{print $2; exit}')"
fi
if [[ -n "$SIGN" ]]; then
  echo "==> Signing DMG: $SIGN"
  codesign --force --timestamp --sign "$SIGN" "$DMG"
  codesign --verify --verbose=2 "$DMG"
else
  echo "==> No Developer ID identity found; DMG container will be unsigned"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

echo "==> Done: $DMG"
ls -lh "$DMG"
