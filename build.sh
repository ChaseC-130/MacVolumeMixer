#!/bin/bash
# Build, bundle, and codesign AppVolumeMixer.
#
# Produces build/AppVolumeMixer.app — a menu-bar (agent) app that controls
# per-application output volume via the Core Audio process-tap API.
#
# Usage:
#   ./build.sh           # build + sign
#   ./build.sh run       # build + sign + launch
set -euo pipefail

APP_NAME="AppVolumeMixer"
BUNDLE_ID="com.antigravity.AppVolumeMixer"
MIN_MACOS="14.2"

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
ENTITLEMENTS="$BUILD/$APP_NAME.entitlements"

echo "==> Cleaning $BUILD"
rm -rf "$BUILD"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> Compiling Swift sources"
# Release build, arm64+x86_64 not needed (dev machine is arm64); target the
# minimum OS that ships the process-tap API.
swiftc -O \
  -o "$MACOS_DIR/$APP_NAME" \
  "$SRC"/*.swift \
  -framework SwiftUI \
  -framework AppKit \
  -framework AudioToolbox \
  -framework AVFoundation \
  -framework Accelerate \
  -target "arm64-apple-macos${MIN_MACOS}"

echo "==> Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>App Volume Mixer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>App Volume Mixer needs to capture system audio so it can adjust the volume of individual apps.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>App Volume Mixer routes per-app audio through a private audio device to control volume.</string>
</dict>
</plist>
EOF

echo "==> Writing entitlements"
cat > "$ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
EOF

# Prefer a stable Developer ID identity: TCC binds the System-Audio-Capture grant
# to the code's designated requirement, which for a Developer ID signature stays
# constant across rebuilds — so you grant the audio permission ONCE. Falls back to
# ad-hoc ("-") if no Developer ID cert is present (then macOS re-prompts each
# rebuild; reset with: tccutil reset SystemAudioCapture $BUNDLE_ID).
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGN="$SIGN_IDENTITY"
else
  SIGN="$(security find-identity -p codesigning -v 2>/dev/null | awk '/Developer ID Application/{print $2; exit}')"
  [[ -z "$SIGN" ]] && SIGN="-"
fi
if [[ "$SIGN" == "-" ]]; then
  # Ad-hoc: no secure timestamp (would need a real identity + network).
  TS_FLAG="--timestamp=none"
  echo "==> Codesigning (ad-hoc + hardened runtime)"
else
  # Developer ID: include a secure timestamp — required for notarization.
  TS_FLAG="--timestamp"
  echo "==> Codesigning (Developer ID + hardened runtime): $SIGN"
fi
codesign --force \
  --options runtime \
  $TS_FLAG \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN" \
  "$APP"

echo "==> Verifying signature"
codesign -dvv "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"

if [[ "${1:-}" == "run" ]]; then
  echo "==> Launching"
  pkill -f "$APP_NAME" 2>/dev/null || true
  sleep 1
  open "$APP"
fi
