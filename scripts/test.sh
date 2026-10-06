#!/usr/bin/env bash
# Generates the project and runs unit tests (and UI tests with --ui) on a simulator.
# Usage: scripts/test.sh [--ui] [--device "iPhone 17"]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="iPhone 17"
ONLY="-only-testing:ZunoTests"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ui) ONLY=""; shift ;;
    --device) DEVICE="$2"; shift 2 ;;
    *) echo "Unknown option $1"; exit 2 ;;
  esac
done
"$ROOT/scripts/generate.sh"
cd "$ROOT"
xcodebuild test \
  -project Zuno.xcodeproj -scheme Zuno -configuration Test \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  $ONLY | tee "$ROOT/build/test.log" | grep -E "Test Suite|Test Case.*(passed|failed)|error:|Executed" || true
grep -q "TEST SUCCEEDED" "$ROOT/build/test.log"
