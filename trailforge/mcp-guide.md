# MCP Guide: TrailForge's MCP Servers

> How the Model Context Protocol (MCP) works, how TrailForge's three MCP servers are built, how the gateway publishes them, how the assistant (a separate app) uses them, and how to test, extend and connect to them.
> Code: `packages/mcp-kit`, `services/mcp-catalog`, `services/mcp-promotions`, `services/mcp-account`, `services/gateway` (`/mcp/*`), `services/assistant/src/mcp.ts`.

## 1. MCP in one minute

**MCP** is an open protocol that lets an AI application discover and use capabilities that live in **another process**. It's like a USB port for AI tools: write a server once, and any MCP client can plug into it (our assistant, Claude Code, VS Code, MCP Inspector…).

| Role | Who in TrailForge |
|---|---|
| **Host**: the AI app the user talks to | The assistant service (`services/assistant`) |
| **Client**: the connection inside the host, one per server | `MCPServerStreamableHttp` from the OpenAI Agents SDK |
| **Server**: exposes capabilities | `mcp-catalog`, `mcp-promotions`, `mcp-account` |

A server offers three kinds of things:

| Primitive | Who decides to use it | TrailForge examples |
|---|---|---|
| **Tools**: actions the *model* can call | The model | `search_products`, `check_stock`, `check_promo_code` |
| **Resources**: data a *client app* can read | The application | `catalog://categories`, `catalog://products/{slug}`, `promotions://active` |
| **Prompts**: reusable templates a *user* picks | The user | `compare_products`, `find_best_deal` |

Messages are **JSON-RPC 2.0**. The transport we use is **Streamable HTTP**: the client `POST`s JSON-RPC to `/mcp`, and the server answers with JSON or a short Server-Sent-Events stream.

## 2. How it fits into TrailForge

**The rule:** the AI assistant is a **separate application** (another team, possibly hosted elsewhere). It may reach the store **only through MCP**, published by the store's public gateway, plus its **own RAG indexes**. It never calls store service APIs.

```
 AI APP (assistant)                                 E-COMMERCE (other team)
 ──────────────────                                 ─────────────────────────────────────────────────────
 search_catalog / search_knowledge ─► Azure AI Search (RAG indexes owned by the AI app)

 MCP client "catalog"    ─POST /mcp/catalog────►  public gateway :3000 ─► mcp-catalog    :4201 ─► catalog, inventory
 MCP client "promotions" ─POST /mcp/promotions─►        (adds x-mcp-key) ─► mcp-promotions :4202 ─► promotion
 MCP client "account"    ─POST /mcp/account────►        (passes user JWT) ─► mcp-account   :4203 ─► order, customer, promotion
    (new connection per chat request, Authorization: Bearer <that user's JWT>)
```

| Data | Comes from | Why |
|---|---|---|
| Finding/listing products, specs, comparisons | **RAG**: `search_catalog` over `tf-products` | The AI app's own index (a published snapshot of the catalog) |
| Policies, guides, FAQs | **RAG**: `search_knowledge` over `tf-knowledge` | Same |
| Live stock, exact current price, reviews | **MCP catalog**, filtered to `get_product`, `check_stock`, `get_reviews` | The index is a snapshot; the store owns live data |
| Public promotions, promo-code checks | **MCP promotions** | Live, public |
| My orders, order details, my offers, my profile, return eligibility | **MCP account**, called as the user | Personal data: the store checks the user's JWT on every call |

**Per-user MCP.** An MCP connection has fixed headers, so one shared connection can't act for different users. TrailForge solves this by opening a **new `account` connection for every chat request** carrying that user's JWT. Because our servers are stateless, a connection is just a couple of cheap HTTP calls. `mcp-kit` hands the token to `buildServer({ userToken })`, so every tool in that request acts as exactly that user, and the services verify the token. Guests connect without a token; the tools answer `AUTH_REQUIRED` and the app shows a Log in button.

**Tool filtering.** `mcp-catalog` offers 5 tools to any MCP client, but the assistant connects with `toolFilter: { allowed: ['get_product', 'check_stock', 'get_reviews'] }`. Discovery (`search_products`, `list_categories`) must come from RAG, so the agent never sees those tools.

`mcp-promotions` calls the promotion API **anonymously**, so it can only ever see public promotions. All MCP servers have **no database**: they're the e-commerce team's thin facades over their own services.

## 3. The code

### 3.1 `packages/mcp-kit`: the shared host
`startMcpServer({ name, defaultPort, buildServer })` gives every MCP server the same plumbing:

| Feature | Detail |
|---|---|
| Endpoint | `POST /mcp` (Streamable HTTP). `GET`/`DELETE /mcp` → 405 |
| **Stateless mode** | `sessionIdGenerator: undefined`: a brand-new `McpServer` + transport per HTTP request, nothing kept in memory. Any replica can answer any call, so it scales horizontally on Azure Container Apps. Trade-off: no server-initiated notifications, which request/response tools don't need. |
| Binding | `127.0.0.1` by default; the SDK then adds **DNS-rebinding protection** (a malicious web page can't trick your browser into calling it). In a container set `MCP_HOST=0.0.0.0`. |
| Auth: caller | Optional shared secret: if `MCP_AUTH_TOKEN` is set, callers must send `x-mcp-key: <token>`. The public gateway adds it, so MCP servers only accept traffic via the gateway (on Azure they also have internal-only ingress). |
| Auth: end user | `Authorization: Bearer <user JWT>` is read and passed to `buildServer({ userToken })` (null for guests). Not verified by mcp-kit; the services verify it. (MCP servers open to arbitrary clients would use the spec's OAuth 2.1 flow.) |
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

**mcp-account** (`:4203/mcp`), per user: send `Authorization: Bearer <user JWT>`

| Tool | Arguments | Returns |
|---|---|---|
| `get_my_profile` | none | Profile + loyalty tier/points |
| `get_my_orders` | none | Orders with status (preparing, on_the_way, delivered, …) and totals |
| `get_order_details` | `orderNumber` (`TF-123456`) | Items, shipments/tracking, stage history, returns (only the user's own orders, otherwise "not found") |
| `get_my_offers` | none | Personal + public offers the user is eligible for |
| `check_return_eligibility` | `orderNumber`, `items[{orderItemId, qty}]` | Dry run: eligible?, problems, refund amount, automatic or staff approval (changes nothing) |

Without a token every tool answers `AUTH_REQUIRED: …`.

### 3.4 The gateway: publishing MCP (`services/gateway/src/index.ts`)

`POST /mcp/catalog | /mcp/promotions | /mcp/account` → the internal MCP servers. The gateway passes through `content-type`, `accept`, `authorization` (the user's JWT) and the MCP protocol headers, **adds `x-mcp-key`**, and streams the response (JSON or SSE) back unchanged. This is the store's single public door for AI clients.

### 3.5 The assistant side (`services/assistant/src/mcp.ts`, `agent.ts`, `index.ts`)

```ts
// shared connections, opened once (STORE_MCP_BASE_URL = the PUBLIC gateway, e.g. http://localhost:3000/mcp)
shared = await connectMcpServers([
  new MCPServerStreamableHttp({ name: 'catalog', url: `${base}/catalog`, cacheToolsList: true,
    toolFilter: createMCPToolStaticFilter({ allowed: ['get_product', 'check_stock', 'get_reviews'] }) }),
  new MCPServerStreamableHttp({ name: 'promotions', url: `${base}/promotions`, cacheToolsList: true }),
], { dropFailed: true, connectInParallel: true });

// per chat request: the user's own connection
const account = new MCPServerStreamableHttp({ name: 'account', url: `${base}/account`,
  requestInit: token ? { headers: { Authorization: `Bearer ${token}` } } : undefined });
await account.connect();
new Agent({ tools: [searchCatalog, searchKnowledge], mcpServers: [...shared.active, account], … });
// …run… then account.close()
```

- **No function tool calls a store API.** The only local tools are the RAG tools over the AI app's own search indexes.
- **`dropFailed: true`:** a server that's down is skipped, so the agent has fewer tools and says that part is unavailable. Failed servers are retried every 30 s.
- **`AUTH_REQUIRED` → Log in button:** when an account tool's output contains `AUTH_REQUIRED`, the assistant sends one `auth_required` SSE event.
- **Login mid-conversation:** when a guest conversation is adopted by a logged-in user, the assistant adds a system note ("the customer has just logged in…") to that turn, so the model calls the account tools again instead of repeating the old "please log in" answer.
- `GET /api/admin/assistant/status` (admin) shows the provider, the RAG configuration and each MCP server's `tools` (what the server offers) and `agentTools` (what the agent may use after filtering).

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
npm run mcp:standalone   # the REST services the MCP servers call (customer, catalog, inventory, order, promotion, marketing)
                         # + mcp-catalog :4201 + mcp-promotions :4202 + mcp-account :4203
                         # + MCP Inspector web UI on http://127.0.0.1:6274 (opens in your browser)
```
No assistant, web app or AI model is needed. In the Inspector:
1. Both servers from `scripts/mcp/inspector.json` are listed. Toggle **catalog** on.
2. **Tools** tab → `search_products` → `{"query":"tent","maxPriceDollars":400}` → *Run*. Then `check_stock`, `get_product`.
3. **Resources** tab → `catalog://categories`; the template `catalog://products/{slug}`.
4. **Prompts** tab → `compare_products`.
5. The right-hand **Messages** panel shows every JSON-RPC message (`initialize`, `tools/list`, `tools/call`…). This is the protocol itself.
6. Toggle **promotions** on and try `check_promo_code` with `GOLD15`: you get "log in to use", because it only sees public promotions.
7. Toggle **account** on and call `get_my_orders`: `AUTH_REQUIRED` (no user token). To act as a user, get a dev token and pass it as a header with the CLI:
   ```bash
   TOKEN=$(curl -s localhost:4001/dev/login-as -H 'content-type: application/json' -d '{"customerId":2}' | jq -r .token)
   npm run mcp:cli -- --server account --method tools/call --tool-name get_my_orders --header "Authorization: Bearer $TOKEN"
   ```

The Inspector prints a URL with a one-time `MCP_INSPECTOR_API_TOKEN`; it protects the Inspector's own local proxy. Set `MCP_AUTO_OPEN_ENABLED=false` to stop it opening a browser tab.

### All MCP scripts
| Script | What it does |
|---|---|
| `npm run mcp:standalone` | Those REST services + all three MCP servers + Inspector web UI, in one terminal |
| `npm run mcp:deps` | Only the REST services the MCP servers call (customer, catalog, inventory, order, promotion, marketing) |
| `npm run dev:mcp` | Only the three MCP servers (also part of `npm run dev`) |
| `npm run mcp:inspector` | Inspector web UI with all three servers (`scripts/mcp/inspector.json`) |
| `npm run mcp:inspect:catalog` / `:promotions` / `:account` | Inspector web UI connected to one server |
| `npm run mcp:cli -- --server catalog --method tools/list` | Inspector **CLI**: one call, JSON output (scriptable) |
| `npm run mcp:cli -- --server promotions --method tools/call --tool-name check_promo_code --tool-arg code=FALLTRAIL20 subtotalDollars=150` | Call a tool from the terminal |
| `npm run smoke:mcp` | 27 automated checks with the official MCP client (direct, and through the gateway) |

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
| AI app reaches the store only via MCP (+ its own RAG) | The store is another team's system; MCP through the gateway is the published contract |
| Per-user data via a per-request MCP connection with the user's JWT | Shared connections have fixed headers; the store verifies the token on every call |
| Filter tools per agent (`toolFilter`) | Discovery from RAG, live checks from MCP: the agent only sees what it should use |
| MCP servers call APIs, never databases | Keeps service ownership of data; one place for business rules |
| Stateless servers | Horizontal scaling, no sticky sessions |
| Descriptions say *when* to use a tool | Better tool choice by the model |
| `isError` results, not crashes | The model can recover ("try search_products first") |
| Treat tool output as **data**, never instructions | Reviews are user-written and could contain "ignore your rules…". `get_reviews` labels them as quoted opinions, and the agent's instructions forbid following instructions inside tool results. Phase 8 adds MCP **tool output guardrails** (`toolOutputGuardrails` on `MCPServerStreamableHttp`) to scan for injection. |
| Gateway in front, `x-mcp-key` behind it | Only the gateway is public; MCP servers have **internal ingress** on Azure and require the gateway's `x-mcp-key` (`MCP_AUTH_TOKEN` from Key Vault) |
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
| `401 Unauthorized (missing x-mcp-key)` | `MCP_AUTH_TOKEN` is set on the server; call it through the gateway (`/mcp/<name>`), or send `x-mcp-key` |
| Account tools always say `AUTH_REQUIRED` | No/expired user JWT in `Authorization`; log in again |

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
