#!/usr/bin/env bash
# =============================================================================
# functions-check.sh - type-check and unit-test the Supabase Edge Functions.
#
#   deno check  every supabase/functions/*/index.ts, handler.ts and _shared/*.ts
#   deno test   every *_test.ts (pure helpers and handlers with injected fakes;
#               no network, no database, no real PayHere/Anthropic/APNs calls)
#
# Environment:
#   DENO       path to the deno binary (default: deno on PATH)
#   DENO_DIR   optional cache directory (deno's default otherwise)
# The first run downloads npm:/jsr: dependencies pinned by supabase/functions/deno.lock.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCTIONS="$ROOT/supabase/functions"
DENO="${DENO:-deno}"
command -v "$DENO" >/dev/null 2>&1 || [ -x "$DENO" ] || { echo "functions-check: deno not found (set DENO)" >&2; exit 2; }

cd "$FUNCTIONS"
echo "== deno $("$DENO" --version | head -1 | awk '{print $2}')"

shopt -s nullglob
targets=(*/index.ts */handler.ts _shared/*.ts)
check_targets=()
for file in "${targets[@]}"; do
  case "$file" in *_test.ts) ;; *) check_targets+=("$file") ;; esac
done

echo "-- deno check (${#check_targets[@]} modules)"
"$DENO" check --config deno.json "${check_targets[@]}"

echo "-- deno test"
# --allow-env: the Anthropic SDK reads its optional ANTHROPIC_* settings from the
# environment at client construction. Tests set no secrets.
"$DENO" test --config deno.json --no-prompt --allow-env .

echo "RESULT: PASS"
