#!/usr/bin/env bash
# Builds the Development configuration and launches Zuno in a simulator.
# Usage: scripts/run-simulator.sh [--device "iPhone 17"] [--no-build] [-- <launch arguments>]
# Example (development backend, signed in): scripts/run-simulator.sh -- -zuno-dev-backend -zuno-signed-in
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="iPhone 17"
BUILD=1
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --) shift; ARGS=("$@"); break ;;
    *) echo "Unknown option $1"; exit 2 ;;
  esac
done
cd "$ROOT"
if [[ $BUILD == 1 ]]; then
  [[ -d Zuno.xcodeproj ]] || scripts/generate.sh
  xcodebuild -project Zuno.xcodeproj -scheme Zuno -configuration Development \
    -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath build/DerivedData build -quiet
fi
UDID=$(xcrun simctl list devices available | grep -E "^\s+$DEVICE \(" | head -1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" build/DerivedData/Build/Products/Development-iphonesimulator/Zuno.app
xcrun simctl launch --terminate-running-process "$UDID" lk.zuno.app.dev "${ARGS[@]+"${ARGS[@]}"}"
