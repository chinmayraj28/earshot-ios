#!/bin/bash
# End-to-end check over a real link: the app in the iOS Simulator connects to
# earshot-probe on this Mac, sends a message, waits for "Delivered" and for the reply.
#
#   Scripts/e2e.sh ["iPhone 17 Pro"]
set -euo pipefail
cd "$(dirname "$0")/.."
SIMULATOR="${1:-iPhone 17 Pro}"

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null
(cd EarshotKit && swift build --product earshot-probe)

LOG="$(mktemp -t earshot-probe)"
EarshotKit/.build/debug/earshot-probe --name Probe --echo >"$LOG" 2>&1 &
PROBE=$!
trap 'kill $PROBE 2>/dev/null || true; echo "--- probe log ---"; cat "$LOG"; rm -f "$LOG"' EXIT

TEST_RUNNER_EARSHOT_LIVE=1 xcodebuild -project Earshot.xcodeproj -scheme Earshot \
  -destination "platform=iOS Simulator,name=$SIMULATOR" -derivedDataPath .build/dd \
  -only-testing:EarshotUITests/LiveLinkTests test \
  | grep -E "error:|Test Case|TEST (SUCCEEDED|FAILED)"
