#!/usr/bin/env bash
# Regenerates Zuno.xcodeproj from project.yml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/bootstrap.sh" >/dev/null
cd "$ROOT"
if command -v xcodegen >/dev/null 2>&1; then XCODEGEN=xcodegen; else XCODEGEN="$ROOT/.tools/xcodegen/bin/xcodegen"; fi
"$XCODEGEN" generate --spec project.yml
