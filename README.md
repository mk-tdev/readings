# Readings

My learning notes, plans and guides from different projects, published with GitHub Pages:
**https://mk-tdev.github.io/readings/**

## Modules

| Module | Folder | Source |
|---|---|---|
| TrailForge: agentic AI e-commerce (Agents SDK, Azure, MCP, RAG, Next.js, microservices) | [`trailforge/`](trailforge/) | private `mk-tdev/trailforge` → `research/` |

Each module folder holds standalone HTML pages (plus the Markdown they were rendered from, readable right here on GitHub).

## Update the TrailForge module

```bash
./scripts/sync-trailforge.sh      # re-renders trailforge/research and copies it here
git add -A && git commit -m "Sync TrailForge guides" && git push
```
GitHub Pages redeploys automatically within a minute or two of the push.

## Add a new module

1. Create a folder, e.g. `my-project/`, with an `index.html` (and any other pages). Use relative links between pages.
2. Add a card for it in the root `index.html` and a row in the table above.
3. Commit and push.

`.nojekyll` makes GitHub Pages serve files exactly as they are (no Jekyll processing).
