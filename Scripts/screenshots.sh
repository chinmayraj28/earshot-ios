#!/usr/bin/env bash
# Regenerates every iPhone screenshot in docs/screenshots/*.png (never docs/screenshots/web/),
# including the photo and formatting screens.
#
#   Scripts/screenshots.sh
#
# Simulator: a dedicated one named "Earshot Shots" (iPhone 17 Pro, iOS 26.x, 1206×2622 px).
# It is created if it doesn't exist, booted, and shut down again at the end. It is never the
# shared "iPhone 17 Pro" simulator, so it can't clash with someone else's test run.
# Override with SIM_NAME=... (it must be an iPhone 17 Pro to keep the same image size).
#
# Needs: Xcode 26 with an iOS 26 Simulator runtime, xcodegen (only if Earshot.xcodeproj
# doesn't exist yet), python3.
#
# One-time setup for the two notification-banner shots: notifications must be allowed for
# Earshot on this simulator, and iOS offers no command-line way to grant that. If the banner
# step fails, open the "Earshot Shots" simulator window, launch Earshot, go to
# Settings › Message alerts › Turn On, tap Allow, and run this script again. The choice is
# kept as long as the simulator isn't erased.
#
# Optional environment:
#   SHOT_TIME=09:41   status-bar time (default: the current time at each step, so it matches
#                     the message times the demo shows, which are relative to now)
#   ONLY=static|flows|banner  only run part of it (default: everything). ONLY=banner retakes
#                     just the two notification-banner images.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM_NAME="${SIM_NAME:-Earshot Shots}"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
DD="$ROOT/.build/dd-shots"
OUT="$ROOT/docs/screenshots"
BUNDLE="app.earshot.Earshot"
SHOT_TIME="${SHOT_TIME:-}"
ONLY="${ONLY:-all}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/earshot-shots.XXXXXX")"
FAILED=()

log() { printf '\n==> %s\n' "$*"; }

# ── Simulator ──────────────────────────────────────────────────────────────────────────
UDID="$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and d.get("isAvailable", True):
            print(d["udid"]); raise SystemExit
' "$SIM_NAME")"
if [[ -z "$UDID" ]]; then
  log "Creating simulator \"$SIM_NAME\""
  UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE")"
fi
echo "Simulator: $SIM_NAME ($UDID)"

ensure_booted() {
  if ! xcrun simctl list devices | grep -q "$UDID) (Booted)"; then
    xcrun simctl boot "$UDID" 2>/dev/null || true
  fi
  xcrun simctl bootstatus "$UDID" -b >/dev/null
}

tidy_status_bar() {
  local args=(--batteryState discharging --batteryLevel 100 --wifiBars 3 --cellularMode notSupported)
  # simctl has once rejected a plain HH:MM time; fall back to 9:41 rather than stop the run.
  xcrun simctl status_bar "$UDID" override --time "${SHOT_TIME:-$(date +%H:%M)}" "${args[@]}" 2>/dev/null \
    || xcrun simctl status_bar "$UDID" override --time "9:41" "${args[@]}"
}

# Changing appearance or text size while Earshot is on screen makes iOS show the home
# indicator over later screenshots, so quit Earshot first and only change what differs.
CUR_APPEARANCE="" CUR_SIZE=""
set_ui() {
  [[ "$1" == "$CUR_APPEARANCE" && "$2" == "$CUR_SIZE" ]] && return 0
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  [[ "$1" != "$CUR_APPEARANCE" ]] && xcrun simctl ui "$UDID" appearance "$1"
  [[ "$2" != "$CUR_SIZE" ]] && xcrun simctl ui "$UDID" content_size "$2"
  CUR_APPEARANCE="$1" CUR_SIZE="$2"
  sleep 3
}

cleanup() {
  xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
  xcrun simctl ui "$UDID" appearance light 2>/dev/null || true
  xcrun simctl ui "$UDID" content_size large 2>/dev/null || true
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ensure_booted
xcrun simctl ui "$UDID" increase_contrast disabled
set_ui light large

# ── Build once ─────────────────────────────────────────────────────────────────────────
cd "$ROOT"
[[ -d Earshot.xcodeproj ]] || xcodegen generate
log "Building app and UI tests (derived data: .build/dd-shots)"
xcodebuild build-for-testing -quiet -project Earshot.xcodeproj -scheme Earshot \
  -destination "id=$UDID" -derivedDataPath "$DD"
APP="$DD/Build/Products/Debug-iphonesimulator/Earshot.app"
xcrun simctl install "$UDID" "$APP"
tidy_status_bar

# ── Screens reachable from launch arguments ────────────────────────────────────────────
# shot <file> <appearance> <text size> [wait seconds] -- <launch arguments...>
shot() {
  local name="$1" appearance="$2" size="$3" wait="$4"; shift 5
  ensure_booted
  set_ui "$appearance" "$size"
  tidy_status_bar
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" "$@" >/dev/null
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "  $name.png"
}

if [[ "$ONLY" == all || "$ONLY" == static ]]; then
  log "Screens from launch arguments"
  L=large; XL=extra-extra-extra-large; AX=accessibility-extra-extra-large
  for appearance in light dark; do
    s=""; [[ $appearance == dark ]] && s="-dark"
    home="home-light"; [[ $appearance == dark ]] && home="home-dark"
    shot "$home"                  $appearance $L 4.5 -- -demo populated
    shot "chat$s"                 $appearance $L 4.5 -- -demo populated -screen "chat:Jensen Huang"
    shot "chat-waiting$s"         $appearance $L 4.5 -- -demo populated -screen "chat:Alice Huang"
    shot "incoming-request$s"     $appearance $L 6   -- -demo populated -demoRequest
    shot "onboarding-welcome$s"   $appearance $L 4.5 -- -demo firstRun
    shot "empty-state$s"          $appearance $L 4.5 -- -demo empty
    shot "settings$s"             $appearance $L 4.5 -- -demo populated -screen settings
    shot "how-it-works$s"         $appearance $L 4.5 -- -demo populated -screen howItWorks
    shot "privacy$s"              $appearance $L 4.5 -- -demo populated -screen privacy
    shot "contact-details$s"      $appearance $L 4.5 -- -demo populated -screen "contact:Jensen Huang"
    shot "bluetooth-denied$s"     $appearance $L 4.5 -- -simulateBluetoothDenied
    # Relaying through friends and the Range test (opt-in demo states).
    shot "relay-sealed$s"         $appearance $L 5   -- -demo populated -demoRelay sealed -screen "chat:Alice Huang"
    shot "relay-delivered$s"      $appearance $L 5   -- -demo populated -demoRelay delivered -screen "chat:Alice Huang"
    shot "relay-settings$s"       $appearance $L 6   -- -demo populated -demoRelay carrying -screen settings:relay
    shot "relay-contact$s"        $appearance $L 5   -- -demo populated -screen "contactRelay:Alice Huang"
    shot "range-test$s"           $appearance $L 5   -- -demo populated -screen rangeTest
  done
  shot home-large-text            light $XL 4.5 -- -demo populated
  shot chat-large-text            light $XL 4.5 -- -demo populated -screen "chat:Alice Huang"
  shot home-accessibility-size    light $AX 4.5 -- -demo populated
  shot settings-accessibility-size light $AX 4.5 -- -demo populated -screen settings
  shot photo-large-text           light accessibility-medium 4.5 -- -demo populated -screen "chat:Alice Huang"
  set_ui light large
fi

# ── Screens that need taps: EarshotUITests/ScreenshotTests and the photo capture test ──
# Attachment name -> file name. "contact-new" is captured by the test but not kept.
MAP='{"nearby-waiting":"nearby-waiting","chat-new-contact":"chat-after-connecting",
      "nearby-failed":"nearby-no-answer","onboarding-name":"onboarding-name",
      "onboarding-how-it-works":"onboarding-how-it-works",
      "notifications-offer":"notifications-offer","notification-banner":"notification-banner",
      "photo-staged":"photo-staged","photo-sending":"photo-sending",
      "chat-formatting-and-photo":"chat-formatting-and-photo",
      "photo-receiving":"photo-receiving","photo-viewer":"photo-viewer",
      "photo-unavailable":"photo-unavailable"}'

# flows <appearance> <Class/test>...
flows() {
  local appearance="$1"; shift
  local suffix=""; [[ $appearance == dark ]] && suffix="-dark"
  local bundle="$WORK/flows-$appearance-$RANDOM.xcresult"
  local only=()
  for t in "$@"; do only+=("-only-testing:EarshotUITests/$t"); done
  ensure_booted
  set_ui "$appearance" large
  tidy_status_bar
  if ! TEST_RUNNER_EARSHOT_SCREENSHOTS=1 xcodebuild test-without-building -quiet \
      -project Earshot.xcodeproj -scheme Earshot -destination "id=$UDID" \
      -derivedDataPath "$DD" -resultBundlePath "$bundle" "${only[@]}" >"$WORK/xcodebuild.log" 2>&1; then
    FAILED+=("$appearance: $*")
    grep -E "error:|failed" "$WORK/xcodebuild.log" | head -5 || true
  fi
  [[ -d "$bundle" ]] || return 0
  local att="$WORK/att-$RANDOM"; mkdir -p "$att"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$att" >/dev/null 2>&1 || return 0
  python3 - "$att" "$OUT" "$suffix" "$MAP" <<'PY'
import json, shutil, sys
att, out, suffix, mapping = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
for test in json.load(open(f"{att}/manifest.json")):
    for a in test["attachments"]:
        name = a["suggestedHumanReadableName"]
        for key, target in mapping.items():
            if name == key or name.startswith(key + "_") or name.startswith(key + "."):
                shutil.copy(f"{att}/{a['exportedFileName']}", f"{out}/{target}{suffix}.png")
                print(f"  {target}{suffix}.png")
PY
}

for appearance in light dark; do
  if [[ "$ONLY" == all || "$ONLY" == flows ]]; then
    log "Tapped flows ($appearance)"
    flows "$appearance" ScreenshotTests/testCaptureFlowScreenshots \
      ScreenshotTests/testCaptureOnboardingScreenshots ScreenshotTests/testCaptureNotificationExplainer \
      PhotoAndFormattingUITests/testCapturePhotoAndFormattingScreenshots
  fi
  if [[ "$ONLY" == all || "$ONLY" == flows || "$ONLY" == banner ]]; then
    log "Notification banner ($appearance)"
    # Separate run: it needs notifications allowed (see the note at the top).
    flows "$appearance" ScreenshotTests/testCaptureNotificationBanner
  fi
done

log "Done: $(ls "$OUT"/*.png | wc -l | tr -d ' ') images in docs/screenshots/"
if (( ${#FAILED[@]} )); then
  echo "Some UI-test captures failed (their previous images were kept):"
  printf '  - %s\n' "${FAILED[@]}"
  echo "If it was testCaptureNotificationBanner, allow notifications once (see the top of this script)."
  exit 1
fi
