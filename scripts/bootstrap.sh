#!/usr/bin/env bash
# Downloads pinned build tools into .tools/ (git-ignored). Safe to re-run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
XCODEGEN_VERSION="2.46.0"
mkdir -p "$TOOLS"
if [[ ! -x "$TOOLS/xcodegen/bin/xcodegen" ]] || ! "$TOOLS/xcodegen/bin/xcodegen" --version | grep -q "$XCODEGEN_VERSION"; then
  echo "Downloading XcodeGen $XCODEGEN_VERSION…"
  curl -fsSL -o "$TOOLS/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  rm -rf "$TOOLS/xcodegen"
  unzip -q -o "$TOOLS/xcodegen.zip" -d "$TOOLS"
  rm "$TOOLS/xcodegen.zip"
fi
"$TOOLS/xcodegen/bin/xcodegen" --version
