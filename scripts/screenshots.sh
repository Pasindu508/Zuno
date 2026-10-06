#!/usr/bin/env bash
# Captures the visual-review screenshot tour on several simulators and exports the
# attachments to artifacts/screenshots/<device>[-<variant>]/<name>.png.
#
# Usage: scripts/screenshots.sh [--devices "iPhone 17e,iPhone 17,iPhone 18 Pro Max"] [--variant dark|light|large-text]
#   light       : forces the app's light appearance (-zuno-light)
#   large-text  : sets the simulator content size to accessibility-extra-extra-large
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICES="iPhone 17e,iPhone 17,iPhone 18 Pro Max"
VARIANT="dark"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --devices) DEVICES="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    *) echo "Unknown option $1"; exit 2 ;;
  esac
done
cd "$ROOT"
[[ -d Zuno.xcodeproj ]] || scripts/generate.sh

IFS=',' read -ra LIST <<< "$DEVICES"
for DEVICE in "${LIST[@]}"; do
  SLUG=$(echo "$DEVICE" | tr '[:upper:] ' '[:lower:]-')
  [[ "$VARIANT" != "dark" ]] && SLUG="$SLUG-$VARIANT"
  UDID=$(xcrun simctl list devices available | grep -E "^\s+$DEVICE \(" | head -1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
  if [[ "$VARIANT" == "large-text" ]]; then
    xcrun simctl ui "$UDID" content_size accessibility-extra-extra-large
  else
    xcrun simctl ui "$UDID" content_size large
  fi
  BUNDLE="build/screenshots-$SLUG.xcresult"
  rm -rf "$BUNDLE"
  EXTRA=()
  # TEST_RUNNER_-prefixed variables reach the UI test runner (read in ZunoUITestCase).
  [[ "$VARIANT" == "light" ]] && EXTRA=(TEST_RUNNER_ZUNO_EXTRA_LAUNCH_ARGS=-zuno-light)
  env "${EXTRA[@]+"${EXTRA[@]}"}" xcodebuild test -project Zuno.xcodeproj -scheme Zuno -configuration Test \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/DerivedData \
    -resultBundlePath "$BUNDLE" -only-testing:ZunoUITests/ScreenshotTour -quiet || echo "warning: tour reported failures on $DEVICE"
  OUT="artifacts/screenshots/$SLUG"
  rm -rf "$OUT" && mkdir -p "$OUT"
  xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$OUT" >/dev/null
  # Rename exported files to the attachment names from the manifest.
  python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
manifest = json.load(open(os.path.join(out, "manifest.json")))
for test in manifest:
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName") or attachment["exportedFileName"]
        base = name.split("_")[0] if name[0:2].isdigit() else name
        src = os.path.join(out, attachment["exportedFileName"])
        if os.path.exists(src):
            os.rename(src, os.path.join(out, base if base.endswith(".png") else base + ".png"))
PY
  xcrun simctl ui "$UDID" content_size large
  echo "screenshots → $OUT"
done
