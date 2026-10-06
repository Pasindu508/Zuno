#!/usr/bin/env bash
# =============================================================================
# seed-storage.sh - upload the development seed cover images to Storage.
#
# Uploads supabase/seed/images/<slug>.jpg to event-media/seed/<slug>.jpg
# (the cover_path values written by supabase/seed.sql). Uses the Storage REST
# API with the service-role key; existing objects are overwritten (x-upsert).
#
# Required environment:
#   SUPABASE_URL                e.g. http://127.0.0.1:54321 or https://<ref>.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY   service-role key (never commit it)
# DEVELOPMENT DATA ONLY - the images are fictional sample artwork.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES="$ROOT/supabase/seed/images"
: "${SUPABASE_URL:?set SUPABASE_URL}"
: "${SUPABASE_SERVICE_ROLE_KEY:?set SUPABASE_SERVICE_ROLE_KEY}"
BASE="${SUPABASE_URL%/}/storage/v1/object/event-media/seed"

shopt -s nullglob
files=("$IMAGES"/*.jpg)
if [ "${#files[@]}" -eq 0 ]; then
  echo "seed-storage: no images found in $IMAGES" >&2
  exit 1
fi

uploaded=0
failed=0
for file in "${files[@]}"; do
  name="$(basename "$file")"
  status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --request POST "$BASE/$name" \
    --header "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    --header "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    --header "Content-Type: image/jpeg" \
    --header "Cache-Control: max-age=31536000" \
    --header "x-upsert: true" \
    --data-binary "@$file")" || status="curl-error"
  if [ "$status" = "200" ] || [ "$status" = "201" ]; then
    echo "uploaded event-media/seed/$name"
    uploaded=$((uploaded + 1))
  else
    echo "FAILED   event-media/seed/$name (HTTP $status)" >&2
    failed=$((failed + 1))
  fi
done

echo "seed-storage: $uploaded uploaded, $failed failed"
[ "$failed" -eq 0 ]
