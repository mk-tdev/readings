#!/usr/bin/env bash
# Copy the agentic-ai course's "101" primers + the Agents SDK roadmap into this repo.
# The source repo is left untouched; only the copies here are adjusted.
#   ./scripts/sync-agentic-ai-101.sh && git add -A && git commit -m "Sync 101 primers" && git push
set -euo pipefail
cd "$(dirname "$0")/.."
SRC_ROOT="${AGENTIC_AI_DIR:-../agentic-ai}/guides"
SRC="$SRC_ROOT/101"
DEST=agentic-ai-101
[ -d "$SRC" ] || { echo "Can't find $SRC (set AGENTIC_AI_DIR)"; exit 1; }
mkdir -p "$DEST"
cp "$SRC"/*.html "$SRC"/*.md "$DEST"/
# The roadmap lives one level up in the course; here it sits next to the primers.
[ -f "$SRC_ROOT/agents-sdk-roadmap.html" ] && cp "$SRC_ROOT/agents-sdk-roadmap.html" "$SRC_ROOT/agents-sdk-roadmap.md" "$DEST"/

for f in "$DEST"/*.html; do
  [ "$(basename "$f")" = index.html ] && continue
  # 1. Full course guides (../04-mcp.md, 05-agents-sdk.md …) live in the private agentic-ai repo → plain text.
  perl -pi -e 's#<a href="(?:\.\./)?\d\d-[\w.-]+\.md">(<code>guides/[^<]+</code>)</a>#$1 (in the agentic-ai course)#g' "$f"
  # 2. Links between primers (and roadmap → primers): .md → the .html page published here.
  perl -pi -e 's#href="(?:101/)?([\w-]+-101)\.md"#href="$1.html"#g' "$f"
  # 3. "Back" links at the top of each page.
  perl -0pi -e 's#<div class="wrap">\n(?!<a class="hub-link")#<div class="wrap">\n<a class="hub-link" href="./" style="display:inline-block;margin:0 0 14px;font-size:14px">← 101 primers</a> · <a class="hub-link" href="../" style="font-size:14px">All readings</a>\n#' "$f"
done
for f in "$DEST"/*.md; do
  perl -pi -e 's#\[`(guides/[\w./-]+\.md)`\]\((?:\.\./)?\d\d-[\w.-]+\.md\)#`$1` (in the agentic-ai course)#g' "$f"
  perl -pi -e 's#\]\(101/([\w-]+-101\.md)\)#]($1)#g' "$f"
done
echo "✓ synced $(ls "$DEST"/*-101.html | wc -l | tr -d ' ') primers$( [ -f "$DEST/agents-sdk-roadmap.html" ] && echo ' + roadmap') from $SRC_ROOT"
