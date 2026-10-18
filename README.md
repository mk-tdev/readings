# Readings

My learning notes, plans and guides from different projects, published with GitHub Pages:
**https://mk-tdev.github.io/readings/**

## Modules

| Module | Folder | Source |
|---|---|---|
| TrailForge: agentic AI e-commerce (Agents SDK, Azure, MCP, RAG, Next.js, microservices) | [`trailforge/`](trailforge/) | private `mk-tdev/trailforge` → `research/` |
| Agentic AI 101s: Agents SDK roadmap + primers (MCP, Azure OpenAI, Azure AI Search, gRPC, context management, human-in-the-loop, sandbox agents, voice agents, testing & evals) | [`agentic-ai-101/`](agentic-ai-101/) | private `mk-tdev/agentic-ai` → `guides/101/` + `guides/agents-sdk-roadmap.md` |

Each module folder holds standalone HTML pages (plus the Markdown they were rendered from, readable right here on GitHub).

## Update the TrailForge module

```bash
./scripts/sync-trailforge.sh      # re-renders trailforge/research and copies it here
git add -A && git commit -m "Sync TrailForge guides" && git push
```
GitHub Pages redeploys automatically within a minute or two of the push.

## Update the 101 primers

```bash
./scripts/sync-agentic-ai-101.sh  # copies agentic-ai/guides/101 + the roadmap, turns course-guide links into plain text, points primer links to .html, adds back links
git add -A && git commit -m "Sync 101 primers" && git push
```

## Add a new module

1. Create a folder, e.g. `my-project/`, with an `index.html` (and any other pages). Use relative links between pages.
2. Add a card for it in the root `index.html` and a row in the table above.
3. Commit and push.

`.nojekyll` makes GitHub Pages serve files exactly as they are (no Jekyll processing).
