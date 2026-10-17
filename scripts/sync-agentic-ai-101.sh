#!/usr/bin/env bash
# Copy the "101" primers from the agentic-ai course into this repo (the source repo is left untouched).
#   ./scripts/sync-agentic-ai-101.sh && git add -A && git commit -m "Sync 101 primers" && git push
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${AGENTIC_AI_DIR:-../agentic-ai}/guides/101"
DEST=agentic-ai-101
[ -d "$SRC" ] || { echo "Can't find $SRC (set AGENTIC_AI_DIR)"; exit 1; }
mkdir -p "$DEST"
cp "$SRC"/*.html "$SRC"/*.md "$DEST"/

# The primers link to the full course guides (../04-mcp.md …), which live in the private
# agentic-ai repo and would 404 here. Keep the reference as plain text instead.
for f in "$DEST"/*.html; do
  perl -pi -e 's#<a href="\.\./[\w.-]+\.md"><code>(guides/[\w.-]+\.md)</code></a>#<code>$1</code> (in the agentic-ai course)#g' "$f"
  # "Back to the hub" link at the top of each page (copies only).
  perl -0pi -e 's#<div class="wrap">\n(?!<a class="hub-link")#<div class="wrap">\n<a class="hub-link" href="./" style="display:inline-block;margin:0 0 14px;font-size:14px">← 101 primers</a> · <a class="hub-link" href="../" style="font-size:14px">All readings</a>\n#' "$f"
done
for f in "$DEST"/*.md; do
  perl -pi -e 's#\[`(guides/[\w.-]+\.md)`\]\(\.\./[\w.-]+\.md\)#`$1` (in the agentic-ai course)#g' "$f"
done
echo "✓ synced $(ls "$DEST"/*.html | grep -v index.html | wc -l | tr -d ' ') primers from $SRC"
