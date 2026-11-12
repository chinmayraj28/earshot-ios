#!/bin/bash
# Installs Earshot on a connected iPhone and starts a Bluetooth test partner on this Mac.
#
#   EARSHOT_TEAM=ABCDE12345 Scripts/device-test.sh [device-name-or-id]
#
# EARSHOT_TEAM is your Apple Developer team ID. Optionally set EARSHOT_BUNDLE_ID if
# "app.earshot.Earshot" cannot be registered under your team.
#
# Afterwards, on the phone: finish onboarding, allow Bluetooth, and tap Connect on
# "Mac Probe". The Mac accepts, and answers every message with "Echo: <text>".
# The first run makes macOS ask whether your terminal may use Bluetooth: allow it.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${EARSHOT_TEAM:?Set EARSHOT_TEAM to your Apple Developer team ID}"
BUNDLE_ID="${EARSHOT_BUNDLE_ID:-app.earshot.Earshot}"
DEVICE="${1:-$(xcrun devicectl list devices 2>/dev/null | grep 'available (paired)' | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)}"
[ -n "$DEVICE" ] || { echo "No paired, available iPhone found. Unlock it and connect it."; exit 1; }

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

echo "Building for device $DEVICE…"
xcodebuild -project Earshot.xcodeproj -scheme Earshot -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath .build/dd-device -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$EARSHOT_TEAM" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build | grep -E "error|BUILD" || true

APP=.build/dd-device/Build/Products/Debug-iphoneos/Earshot.app
[ -d "$APP" ] || { echo "Build failed."; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || true

echo
echo "Starting the Mac test partner over Bluetooth (Ctrl-C to stop)…"
cd EarshotKit
EARSHOT_BT_DEBUG=1 swift run earshot-probe --name "Mac Probe" --echo --bluetooth
