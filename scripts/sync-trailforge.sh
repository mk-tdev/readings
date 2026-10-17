#!/usr/bin/env bash
# Copy the latest TrailForge research guides into this repo (source repo is left untouched).
#   ./scripts/sync-trailforge.sh && git add -A && git commit -m "Sync TrailForge guides" && git push
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${TRAILFORGE_DIR:-../trailforge}/research"
[ -d "$SRC" ] || { echo "Can't find $SRC (set TRAILFORGE_DIR)"; exit 1; }
# Re-render HTML from the markdown first, so the copy is current.
( cd "$SRC/.." && npm run --silent research:html )
mkdir -p trailforge
cp "$SRC"/*.html "$SRC"/*.md trailforge/
# Add a "back to the hub" link to each copied page's sidebar (copies only).
for f in trailforge/*.html; do
  perl -0pi -e 's#<nav><b>TrailForge research</b>#<nav><a href="../" class="hub-link">← All readings</a><b>TrailForge research</b>#' "$f"
done
echo "✓ synced $(ls trailforge/*.html | wc -l | tr -d ' ') HTML pages from $SRC"
