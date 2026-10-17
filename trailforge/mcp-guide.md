# MCP Guide: TrailForge's MCP Servers

> How the Model Context Protocol (MCP) works, how TrailForge's two MCP servers are built, how the assistant uses them, and how to test, extend and connect to them.
> Code: `packages/mcp-kit`, `services/mcp-catalog`, `services/mcp-promotions`, `services/assistant/src/mcp.ts`.

## 1. MCP in one minute

**MCP** is an open protocol that lets an AI application discover and use capabilities that live in **another process**. It's like a USB port for AI tools: write a server once, and any MCP client can plug into it (our assistant, Claude Code, VS Code, MCP Inspector…).

| Role | Who in TrailForge |
|---|---|
| **Host**: the AI app the user talks to | The assistant service (`services/assistant`) |
| **Client**: the connection inside the host, one per server | `MCPServerStreamableHttp` from the OpenAI Agents SDK |
| **Server**: exposes capabilities | `mcp-catalog`, `mcp-promotions` |

A server offers three kinds of things:

| Primitive | Who decides to use it | TrailForge examples |
|---|---|---|
| **Tools**: actions the *model* can call | The model | `search_products`, `check_stock`, `check_promo_code` |
| **Resources**: data a *client app* can read | The application | `catalog://categories`, `catalog://products/{slug}`, `promotions://active` |
| **Prompts**: reusable templates a *user* picks | The user | `compare_products`, `find_best_deal` |

Messages are **JSON-RPC 2.0**. The transport we use is **Streamable HTTP**: the client `POST`s JSON-RPC to `/mcp`, and the server answers with JSON or a short Server-Sent-Events stream.

## 2. How it fits into TrailForge

```
 browser ─► gateway ─► assistant (MCP host, OpenAI Agents SDK)
                          │
                          ├─ MCP client ──POST /mcp──► mcp-catalog    :4201 ──REST──► catalog service   :4002
                          ├─ MCP client ──POST /mcp──► mcp-promotions :4202 ──REST──► promotion service :4006
                          │
                          └─ function tools (private, with the user's JWT) ──REST──► order · promotion · customer
```

**Public data via MCP, private data via function tools.** This is the key rule:

| Data | Where the tool lives | Why |
|---|---|---|
| Products, stock, reviews, categories, public promotions | MCP servers | Same for everyone; reusable by any MCP client; can scale separately |
| My orders, my offers, my profile | Assistant function tools (`tools/private.ts`) | Needs *this* user's identity. An MCP connection is created once with fixed headers, so it can't carry a different user's JWT on each call. The tool reads the token from the Agents SDK `RunContext`. |

`mcp-promotions` calls the promotion API **anonymously**, so even if someone talks to it directly it can only see public promotions. Member-only codes answer "Log in to use GOLD15".

The MCP servers have **no database**. They're thin facades over the services' REST APIs, so the "each service owns its data" rule still holds.

## 3. The code

### 3.1 `packages/mcp-kit`: the shared host
`startMcpServer({ name, defaultPort, buildServer })` gives every MCP server the same plumbing:

| Feature | Detail |
|---|---|
| Endpoint | `POST /mcp` (Streamable HTTP). `GET`/`DELETE /mcp` → 405 |
| **Stateless mode** | `sessionIdGenerator: undefined`: a brand-new `McpServer` + transport per HTTP request, nothing kept in memory. Any replica can answer any call, so it scales horizontally on Azure Container Apps. Trade-off: no server-initiated notifications, which request/response tools don't need. |
| Binding | `127.0.0.1` by default; the SDK then adds **DNS-rebinding protection** (a malicious web page can't trick your browser into calling it). In a container set `MCP_HOST=0.0.0.0`. |
| Auth | Optional shared secret: if `MCP_AUTH_TOKEN` is set, callers must send `Authorization: Bearer <token>`. (Public MCP servers would use the spec's OAuth 2.1 flow; ours are internal-only.) |
| Health | `GET /healthz` |
| Helpers | `text()`, `json()`, `toolError()`, `usd()` to build tool results |

### 3.2 Anatomy of a tool (`services/mcp-catalog/src/index.ts`)

```ts
server.registerTool(
  'check_stock',                                   // ① name: what the model calls
  {
    title: 'Check stock',
    description: 'Live availability for a product, optionally for a specific size and/or colour. ' +
                 'Use before telling a customer something is available.',   // ② WHEN to use it
    inputSchema: {                                 // ③ zod → JSON Schema the model fills in
      slug: z.string(),
      size: z.string().optional().describe('e.g. "M", "US 10"'),
      color: z.string().optional(),
    },
    outputSchema: { product: z.string(), variants: z.array(/* … */) },  // ④ optional typed output
    annotations: { readOnlyHint: true, openWorldHint: false },          // ⑤ hints for clients
  },
  async ({ slug, size, color }) => {               // ⑥ handler: validated args in, result out
    const p = await services.catalog(`/products/${slug}`);  // calls the REST API, not a database
    // …filter variants…
    return { ...text(summary), structuredContent: { product: p.name, variants } };
  },
);
```

| Part | Why it matters |
|---|---|
| ① name + ② description | **The description is the prompt.** The model sees only names, descriptions and schemas when choosing tools, so say *when* to use the tool and what comes back. |
| ③ `inputSchema` | Arguments are validated before your code runs; `.describe()` text helps the model fill them in |
| ④ `outputSchema` / `structuredContent` | Machine-readable result next to the human-readable text (used by `check_stock`) |
| ⑤ `annotations` | `readOnlyHint`, `destructiveHint`, `openWorldHint`: hints a host can use (e.g. auto-approve read-only tools) |
| Errors | Return `toolError('…')` (`isError: true`) for problems the model can fix ("unknown slug, use search_products"). If the handler **throws** (e.g. the catalog service is down), the SDK also turns it into an `isError` result, so the model sees the message instead of the run crashing. |

### 3.3 What each server exposes

**mcp-catalog** (`:4201/mcp`)

| Tool | Arguments | Returns |
|---|---|---|
| `search_products` | `query?`, `category?` (enum of 10), `brand?`, `minPriceDollars?`, `maxPriceDollars?`, `inStockOnly`, `sort`, `limit` | Ranked list with price, rating, stock, slug |
| `get_product` | `slug` | Description, highlights, specs, uses, warranty, every variant with live price/stock |
| `check_stock` | `slug`, `size?`, `color?` | Per-variant availability (+ `structuredContent`) |
| `get_reviews` | `slug`, `limit` | Average rating + recent reviews, labelled as quoted customer opinions |
| `list_categories` | none | Slug, name, description, product count |

Resources: `catalog://categories`, and the **resource template** `catalog://products/{slug}` (one URI pattern → a resource per product). Prompt: `compare_products(slugs, useCase?)`.

**mcp-promotions** (`:4202/mcp`)

| Tool | Arguments | Returns |
|---|---|---|
| `list_public_promotions` | `category?` | Code, offer, conditions, end date |
| `check_promo_code` | `code`, `subtotalDollars`, `categories[]` | Valid + estimated saving, or the exact reason it can't be used (expired, minimum spend, member-only → log in) |
| `get_promotion_terms` | `code` | Full terms of one public code |

Resource: `promotions://active`. Prompt: `find_best_deal(shoppingList)`.

### 3.4 The assistant side (`services/assistant/src/mcp.ts` + `agent.ts`)

```ts
mcp = await connectMcpServers(
  [server('catalog', MCP_CATALOG_URL), server('promotions', MCP_PROMOTIONS_URL)],
  { dropFailed: true, connectInParallel: true, connectTimeoutMs: 5000 },
);
// per chat request:
new Agent({ tools: [...privateTools, ...fallbacks], mcpServers: mcp.active, … });
```

- **`dropFailed: true`:** a server that's down is skipped instead of crashing the assistant; failed servers are retried every 30 s, so start-up order doesn't matter.
- **`cacheToolsList: true`:** tools are listed once, not on every agent turn.
- **Fallbacks:** if `catalog` isn't connected, the local function tools `search_products` + `get_product_details` are added; if `promotions` isn't, `get_public_promotions`. Names never clash because a fallback is only added when its MCP server is missing.
- The agent is built **per request** (`createAssistant()`), so a server that comes back is picked up on the next message.
- `GET /api/admin/assistant/status` (admin) shows `{ model, mcp: [{ name, connected, tools[] }] }`.

## 4. What happens on the wire

```
client                                    mcp-catalog
  │  POST /mcp  initialize ─────────────────►│  "I support tools, resources, prompts"
  │  POST /mcp  tools/list ─────────────────►│  names + descriptions + JSON Schemas
  │  … the model decides to call a tool …    │
  │  POST /mcp  tools/call check_stock ─────►│──► GET catalog:4002/products/<slug>
  │◄──────────── result (content + structuredContent)
```

Try it with plain `curl` (both `Accept` types are required by Streamable HTTP):

```bash
curl -s localhost:4201/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"check_stock","arguments":{"slug":"ridgeline-2p-ultralight-tent"}}}'
# event: message
# data: {"result":{"content":[{"type":"text","text":"Ridgeline 2P Ultralight Tent\nForest Green: 24 available…"}],
#        "structuredContent":{…}},"jsonrpc":"2.0","id":1}
```

Other methods to try: `initialize`, `tools/list`, `resources/list`, `resources/templates/list`, `resources/read` (`{"uri":"promotions://active"}`), `prompts/list`, `prompts/get`.

## 5. Running and testing

### Standalone: just the MCP servers, nothing else
```bash
npm run db:up            # Postgres
npm run mcp:standalone   # catalog :4002 + inventory :4003 + promotion :4006 (what the MCP servers call)
                         # + mcp-catalog :4201 + mcp-promotions :4202
                         # + MCP Inspector web UI on http://127.0.0.1:6274 (opens in your browser)
```
No assistant, web app or AI model is needed. In the Inspector:
1. Both servers from `scripts/mcp/inspector.json` are listed. Toggle **catalog** on.
2. **Tools** tab → `search_products` → `{"query":"tent","maxPriceDollars":400}` → *Run*. Then `check_stock`, `get_product`.
3. **Resources** tab → `catalog://categories`; the template `catalog://products/{slug}`.
4. **Prompts** tab → `compare_products`.
5. The right-hand **Messages** panel shows every JSON-RPC message (`initialize`, `tools/list`, `tools/call`…). This is the protocol itself.
6. Toggle **promotions** on and try `check_promo_code` with `GOLD15`: you get "log in to use", because it only sees public promotions.

The Inspector prints a URL with a one-time `MCP_INSPECTOR_API_TOKEN`; it protects the Inspector's own local proxy. Set `MCP_AUTO_OPEN_ENABLED=false` to stop it opening a browser tab.

### All MCP scripts
| Script | What it does |
|---|---|
| `npm run mcp:standalone` | The three REST services + both MCP servers + Inspector web UI, in one terminal |
| `npm run mcp:deps` | Only the three REST services (catalog, inventory, promotion) |
| `npm run dev:mcp` | Only the two MCP servers (also part of `npm run dev`) |
| `npm run mcp:inspector` | Inspector web UI with both servers (`scripts/mcp/inspector.json`) |
| `npm run mcp:inspect:catalog` / `mcp:inspect:promotions` | Inspector web UI connected to one server |
| `npm run mcp:cli -- --server catalog --method tools/list` | Inspector **CLI**: one call, JSON output (scriptable) |
| `npm run mcp:cli -- --server promotions --method tools/call --tool-name check_promo_code --tool-arg code=FALLTRAIL20 subtotalDollars=150` | Call a tool from the terminal |
| `npm run smoke:mcp` | 19 automated checks with the official MCP client |

### With the full app
```bash
npm run dev              # everything; the assistant connects to both MCP servers
```

`npm run smoke:mcp` connects exactly like a real host. It lists and calls every tool, reads every resource (including the template), fetches every prompt, and checks the error cases (unknown slug → `isError`, expired code, member-only code → "log in").

### Use them from other MCP clients
Because they speak standard MCP, other AI tools on your machine can use them too, as long as `npm run dev:services` and `npm run dev:mcp` are running:

- **Claude Code:** `claude mcp add --transport http trailforge-catalog http://localhost:4201/mcp`
- **VS Code** (`.vscode/mcp.json`):
  ```json
  { "servers": { "trailforge-catalog": { "type": "http", "url": "http://localhost:4201/mcp" } } }
  ```
- **MCP Inspector:** `npm run mcp:inspector`.

If `MCP_AUTH_TOKEN` is set, add the `Authorization: Bearer …` header in the client's config. Check each client's current docs for its exact config format.

## 6. Extending

### Add a tool (example: `list_brands` in mcp-catalog)
1. Make sure the data is available from a service API (add an endpoint to the catalog service if needed; MCP servers never query a database).
2. In `services/mcp-catalog/src/index.ts`, inside `buildServer()`:
   ```ts
   server.registerTool(
     'list_brands',
     {
       title: 'List brands',
       description: 'All brands TrailForge sells, with how many products each has. Use when the customer asks which brands we carry.',
       inputSchema: { category: z.enum(CATEGORIES).optional() },
       annotations: { readOnlyHint: true, openWorldHint: false },
     },
     async ({ category }) => {
       const { items } = await services.catalog<{ items: { brand: string }[] }>('/products', { query: { category, pageSize: 48 } });
       const counts = Object.entries(items.reduce<Record<string, number>>((m, p) => ((m[p.brand] = (m[p.brand] ?? 0) + 1), m), {}));
       return json(counts.map(([brand, products]) => ({ brand, products })));
     },
   );
   ```
3. `tsx watch` restarts the server. The assistant lists tools on connect (cached), so restart the assistant or wait for it to reconnect.
4. Add a check to `scripts/smoke/mcp-smoke.mjs` (update the expected tool count).
5. Update `research/architecture.md` §MCP servers and this guide.

### Add a new MCP server (example: `mcp-stores`)
1. Copy `services/mcp-promotions` → `services/mcp-stores`; set `"name": "@tf/mcp-stores"` in `package.json`.
2. Add `'mcp-stores': { port: 4203 }` to `MCP_SERVERS` and `MCP_STORES_URL` to the config in `packages/shared/src/config.ts` (+ `.env.example`).
3. Add `{ "path": "services/mcp-stores" }` to the root `tsconfig.json`, and `"npm:dev -w @tf/mcp-stores"` to the root `dev:mcp` script.
4. Register it in `services/assistant/src/mcp.ts` (`server('stores', config.MCP_STORES_URL)`).
5. `npm install`, `npm run typecheck`, `npm run dev`.

## 7. Design rules & security

| Rule | Why |
|---|---|
| Public data only on MCP | Shared connections can't carry per-user identity; private tools use `RunContext` |
| MCP servers call APIs, never databases | Keeps service ownership of data; one place for business rules |
| Stateless servers | Horizontal scaling, no sticky sessions |
| Descriptions say *when* to use a tool | Better tool choice by the model |
| `isError` results, not crashes | The model can recover ("try search_products first") |
| Treat tool output as **data**, never instructions | Reviews are user-written and could contain "ignore your rules…". `get_reviews` labels them as quoted opinions, and the agent's instructions forbid following instructions inside tool results. Phase 8 adds MCP **tool output guardrails** (`toolOutputGuardrails` on `MCPServerStreamableHttp`) to scan for injection. |
| Internal-only network + optional token | On Azure the MCP servers get **internal ingress** only; `MCP_AUTH_TOKEN` comes from Key Vault |
| Localhost bind in dev | DNS-rebinding protection from the SDK |

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `curl` returns `406` / "Not Acceptable" | Send `accept: application/json, text/event-stream` |
| `GET /mcp` → 405 | Expected: stateless servers only accept `POST` |
| Tool result: `localhost:4002 unreachable` | The REST service behind it isn't running → `npm run dev:services` |
| Assistant status shows `connected: false` | Start `npm run dev:mcp`; the assistant retries every 30 s (or restart it) |
| New tool not visible to the assistant | Tools are cached per connection → restart the assistant |
| `EADDRINUSE :4201` | An MCP server is already running (maybe from an earlier terminal) → `lsof -nP -iTCP:4201 -sTCP:LISTEN` |
| `401 Unauthorized` | `MCP_AUTH_TOKEN` is set on the server; send the same token from the client |

## 9. Cheat sheet

```bash
npm run dev:mcp                     # start both MCP servers
npm run smoke:mcp                   # verify every tool/resource/prompt
npm run mcp:inspector               # UI: Streamable HTTP → http://localhost:4201/mcp
curl -s localhost:4202/healthz      # health
# status as seen by the assistant (admin JWT):
curl -s localhost:3000/api/admin/assistant/status -H "authorization: Bearer <admin token>"
```

Related: [Architecture & Contracts](architecture.md) (MCP section) · [Implementation Plan](implementation-plan.md) (Phase 5) · [Monorepo Guide](monorepo-guide.md)
