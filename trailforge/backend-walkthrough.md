# Backend Walkthrough: How the Node.js Services and the AI Agent Work

> A guided tour of TrailForge's **backend and AI code** (no front-end). How a request travels through the gateway, how services call each other, how the assistant runs an agent, and how it reaches **Azure OpenAI**, **Azure AI Search** (RAG) and the store's **MCP servers**.
> Every section points to real files. Read it next to the code. Paths are relative to the repo root.

## 1. The 30-second map

```
                        ┌──────────────────────────── E-COMMERCE SIDE ─────────────────────────────┐
 browser / Next.js BFF  │                                                                          │
 ──────────────────────►│  gateway :3000  (services/gateway)                                       │
   /api/products …      │     │  forward() ──HTTP──► customer :4001  catalog :4002  inventory :4003 │
   /api/orders …        │     │                      order :4004  payment :4005  promotion :4006   │
   /api/chat  ───┐      │     │                      marketing :4007        (each has its own DB)  │
                 │      │     │                                                                    │
                 │      │     └─ /mcp/catalog|promotions|account ──► mcp-catalog :4201             │
                 │      │                                            mcp-promotions :4202          │
                 │      │                                            mcp-account :4203 ──► services │
                 │      └──────────────────────────────────────────────────────────────────────────┘
                 │                     ▲ MCP over HTTP (via the gateway only)
                 ▼                     │
        ┌──────────── AI SIDE (a separate app) ─────────────┐
        │ assistant :4100  (services/assistant)               │
        │   OpenAI Agents SDK agent                           │──► Azure OpenAI  (chat model + embeddings)
        │   RAG tools ────────────────────────────────────────│──► Azure AI Search (one index: tf-rag)    
        │   own DB: conversations (chat memory)               │
        └─────────────────────────────────────────────────────┘
```

There are two kinds of traffic:
1. **Store traffic.** The browser asks for products or orders → **gateway** → the right **service** → its **Postgres database**.
2. **AI traffic.** The browser sends a chat message → gateway → **assistant**. The assistant's agent then reaches out to:
   - **Azure OpenAI**, to think and to embed text;
   - **Azure AI Search**, for RAG answers;
   - the store's **MCP servers**, *through the gateway*, for live stock, promotions and the user's own orders.

Every box is a separate Node.js process (`npm run dev` starts them all). They talk **only over HTTP**.

## 2. The building blocks every service shares (`packages/shared/src`)

All Express services are built from the same small toolkit, so learn it once.

### 2.1 `createService()`: the Express app factory (`http.ts`)

```ts
export function createService(name) {
  const app = express();
  app.use(express.json({ limit: '1mb' }));   // ① parse JSON bodies into req.body
  app.use(/* log every request */);           // ② "GET /me/orders → 200 12ms"
  app.use(authenticate);                      // ③ read the JWT / internal token → req.auth
  app.get('/healthz', …);                     // ④ health check for Docker/Azure
  function start() {
    app.use(/* 404 for unknown routes */);    // ⑥ after all routes
    app.use(errorHandler(name));              // ⑦ turn thrown errors into JSON
    return app.listen(port);
  }
  return { app, start };
}
```

A service file is therefore always: `const { app, start } = createService('order')` → register routes (⑤) → `start()`.

**Request lifecycle inside one service:**
```
HTTP request → express.json → logger → authenticate (sets req.auth) → your route handler
             → (throws HttpError?) → errorHandler → {"error":{"code","message"}} with the right status
```

Express 5 forwards errors thrown in `async` handlers to the error handler automatically. That's why route code just writes `throw notFound('Order')` and never has to wrap anything in `try/catch`.

### 2.2 Errors (`errors.ts`)
```ts
export class HttpError extends Error { constructor(public status, public code, message, public details?) … }
export const notFound = (what = 'Resource') => new HttpError(404, 'NOT_FOUND', `${what} not found`);
```
The `errorHandler` sends `{ error: { code, message, details } }` with that status. Validation errors from **zod** (`parse(schema, req.body)`) become `400 BAD_REQUEST` automatically.

### 2.3 Auth (`auth.ts`): two ways to call a service
| Header | Who sends it | Means |
|---|---|---|
| `Authorization: Bearer <JWT>` | Browser (via gateway), MCP servers | "I'm **this customer**". The JWT is signed by the customer service at login (`signToken`, HS256, 7 days) |
| `x-internal-token: <INTERNAL_TOKEN>` | One store service calling another | "I'm a **trusted internal service**" (may act for any customer) |

`authenticate` **never rejects**; it only fills `req.auth`:
```ts
req.auth = { customerId: null, role: null, internal: false };
if (req.headers['x-internal-token'] === config.INTERNAL_TOKEN) req.auth.internal = true;
if (authorization starts with 'Bearer ') req.auth = { ...(await verifyToken(jwt)), internal: … };
```
**Guards** decide per route:
- `requireCustomer` → 401 unless logged in;
- `requireAdmin` → admins (or internal calls) only;
- `requireInternal` → internal service calls (or admins) only.

`actingCustomerId(req)` returns *whose* data to use. A customer always gets **their own id**, taken from the verified JWT; only an internal caller may pass `?customerId=`. That one function is why a customer can never read someone else's orders.

### 2.4 Calling another service: `services.<name>()` (`client.ts`)
```ts
export const services = { customer: serviceClient(CUSTOMER_URL), order: serviceClient(ORDER_URL), … };

await services.order('/me/orders', { token: userJwt });                    // act as the user
await services.inventory('/reservations', { internal: true, body: {...} }); // act as a trusted service
```
What `serviceClient` does on every call:
1. Builds the URL plus query string, and sets `content-type`, `authorization` (if `token`) and `x-internal-token` (if `internal`).
2. Calls `fetch` with a **15-second timeout**. If the network fails, it throws `HttpError(503, 'SERVICE_UNAVAILABLE')`.
3. If the other service answered with an error, it **re-throws the same status and code**. So a `402 PAYMENT_DECLINED` from the payment service travels unchanged through the order service and the gateway to the browser.

### 2.5 Database helpers (`db.ts`, `migrate.ts`)
- `createPool('tf_order')`: one Postgres connection pool per service, **only its own database**.
- `one(db, sql, params)` / `many(...)`: run SQL and convert `snake_case` columns into `camelCase` objects (`total_cents` → `totalCents`).
- `tx(db, async (c) => { … })`: `BEGIN` … `COMMIT`, or `ROLLBACK` if anything throws.
- SQL is plain and parameterised (`$1`, `$2`) to prevent SQL injection. Schema lives in `services/<name>/migrations/*.sql`, applied by `npm run db:migrate`.

### 2.6 Configuration (`config.ts`, `ai.ts`)
All settings come from environment variables (root `.env` locally), validated once with **zod**: service URLs, `JWT_SECRET`, `INTERNAL_TOKEN`, MCP URLs. `aiSettings()` decides the AI provider (`MODEL_PROVIDER=azure|openai|auto`) and which deployment and model names to use.

## 3. The gateway (`services/gateway/src/index.ts`)

The gateway is the **only** public backend entry point. It:
1. **maps public `/api/*` routes** onto internal services;
2. **passes the user's JWT through**, so services authorize the user themselves;
3. **aggregates** data from several services where the UI needs it;
4. **streams chat** from the assistant;
5. **publishes the MCP servers** at `/mcp/*` for the AI app.

It **never exposes** `/internal/*` service routes.

### 3.1 `forward()`: the heart of the gateway
```ts
function forward(svc, path, status = 200) {
  return async (req, res) => {
    const data = await services[svc](path(req), {
      method: req.method,
      token: req.auth.token,        // the caller's JWT, passed through unchanged
      query: req.query,
      body: ['POST','PATCH','PUT'].includes(req.method) ? req.body : undefined,
    });
    res.status(status).json(data);
  };
}

app.get('/api/me/orders', requireCustomer, forward('order', p('/me/orders')));
app.get('/api/products/:slug', forward('catalog', (r) => `/products/${encodeURIComponent(r.params.slug)}`));
```
Each route is one line: an optional guard (`requireCustomer` rejects early with 401), then `forward(service, path)`. The service does the real work and the real authorization.

### 3.2 Aggregation: one call, several services
`GET /api/admin/orders` asks the **order** service for orders and the **customer** service for names *in parallel* (`Promise.all`), then joins them, so the admin table shows "Alex Rivera" instead of `customerId: 2`. `GET /api/me/summary` does the same with three services, using `Promise.allSettled` so one failing service doesn't break the page.

### 3.3 Streaming chat: `proxyStream()`
```ts
const upstream = await fetch(ASSISTANT_URL + '/chat', { method: 'POST', headers: { authorization }, body, signal });
res.setHeader('content-type', upstream.headers.get('content-type'));   // text/event-stream
res.flushHeaders();
for await (const chunk of upstream.body) res.write(chunk);               // pass each piece through immediately
```
- The assistant answers with **Server-Sent Events (SSE)**: a long HTTP response where each event is `event: delta\ndata: {"text":"Hel"}\n\n`.
- The gateway **doesn't wait** for the whole answer. It copies chunks as they arrive, which is how text appears token by token.
- `res.on('close', () => ac.abort())`: if the user closes the tab or presses *Stop*, the gateway aborts the upstream request, and the assistant stops the agent run (and the token spending).

### 3.4 Publishing MCP: `app.all('/mcp/:server')`
```ts
const MCP_TARGETS = { catalog: MCP_CATALOG_URL, promotions: MCP_PROMOTIONS_URL, account: MCP_ACCOUNT_URL };
// copy content-type, accept, authorization (user JWT), mcp-protocol-version …
headers['x-mcp-key'] = MCP_AUTH_TOKEN;            // proves "this came through the gateway"
const upstream = await fetch(target, { method, headers, body });
// stream the JSON or SSE response back unchanged
```
The AI app calls `http://<gateway>/mcp/account` and the gateway relays it to the internal MCP server. More in §7.

### 3.5 Trace 1: "show my orders"
```
1. Browser → Next.js BFF  GET /api/me/orders       (cookie holds the JWT; the BFF adds Authorization: Bearer <jwt>)
2. BFF     → gateway     GET :3000/api/me/orders  Authorization: Bearer <jwt>
3. gateway: authenticate → req.auth.customerId = 2 · requireCustomer ✓ · forward('order', '/me/orders')
4. gateway → order       GET :4004/me/orders      Authorization: Bearer <jwt>   (same JWT)
5. order:   authenticate verifies the JWT again (never trusts the gateway blindly)
            actingCustomerId(req) → 2 (from the JWT, not from the URL)
            SQL: SELECT … FROM orders WHERE customer_id = $1 … [2]  → camelCase rows
6. order   → gateway → BFF → browser: JSON array of the customer's orders
```

## 4. Services calling services (`services/order`)

The **checkout** (`POST /orders` in `services/order/src/index.ts`) is the best example of microservices working together. It's a **saga**: a sequence of calls to other services, with **compensating actions** if a later step fails.

```
order service                       other services                         on failure
─────────────                       ──────────────                         ──────────
1. quote()  ── Promise.all ─────►  catalog  (prices, product info)  ┐
                                    inventory (availability)         ├ in parallel
                                    promotion (is the code valid?)  ┘
2. get address  ───────────────►  customer (/me/addresses, internal)
3. INSERT order 'pending' + item snapshots  (own DB, one transaction)
4. reserve stock ──────────────►  inventory /reservations (row lock: no overselling)
5. charge card  ───────────────►  payment  /payments               ─► release reservation, mark cancelled, rethrow
6. commit stock ───────────────►  inventory /reservations/:id/commit
7. status → 'preparing'
8. side effects (Promise.allSettled: may fail without failing the order)
                ───────────────►  promotion (record redemption) · customer (loyalty points) · marketing (inbox message)
```

Things to notice in the code:
- **Prices come from the server**, not the browser: `quote()` asks the catalog for current prices.
- **`{ internal: true }`** on calls the customer isn't directly allowed to make (reserve stock, charge, add points).
- **Order items are snapshots** (name, price at purchase), so a later catalog change never rewrites history.
- **`try { reserve → charge → commit } catch { release; cancel; throw }`** is the compensating action.
- **`Promise.allSettled`** for non-critical side effects: a marketing outage must not cancel a paid order.
- The inventory service uses `SELECT … FOR UPDATE` (a row lock) inside a transaction, so two simultaneous checkouts can't both buy the last tent.

## 5. The AI side: the assistant service (`services/assistant/src`)

| File | Job |
|---|---|
| `index.ts` | Express app: `POST /chat` (SSE), conversation history, `/status`, approvals |
| `agent.ts` | Builds the **Agent**: model, instructions, tools, MCP servers |
| `openai.ts` | Creates the OpenAI client for **Azure OpenAI** (or OpenAI) |
| `rag.ts` | RAG tools `search_catalog` and `search_knowledge` → **Azure AI Search** |
| `mcp.ts` | MCP **client** connections to the store (via the gateway) |
| `session.ts` | `PostgresSession`: chat memory stored in Postgres |
| `context.ts` | `ShopContext`: per-request data the tools can use but the model never sees |

**Golden rule:** the assistant is a *separate app*. It makes **no** `services.*` calls to store APIs. Store data comes only through **MCP**; product and policy knowledge comes from its own **RAG** indexes.

## 6. Trace 2: one chat message, end to end

User (logged in as Alex) types: *"Is my latest order on the way, and can I return a GPS watch after 45 days?"*

### Step 1: gateway → assistant
`POST /api/chat` → `proxyStream()` → `POST :4100/chat` with the JWT (§3.3).

### Step 2: who is it, and which conversation? (`index.ts`)
```ts
const auth = req.auth;                                    // from the JWT: customerId 2, name "Alex Rivera"
const conv = await resolveConversation(conversationId, auth.customerId);
```
`resolveConversation` applies privacy rules:
- **New** → create a row in `conversations`.
- **Guest conversation, user now logged in** → *adopt* it (`adopted: true`).
- **Belongs to someone else** → start a fresh one, so a different person never sees the history.

### Step 3: open the SSE stream and tell the browser the basics
```ts
res.writeHead(200, { 'content-type': 'text/event-stream', … });
send('meta', { conversationId, authenticated: true, customerName: 'Alex Rivera' });
```

### Step 4: build the **RunContext** (private to the server)
```ts
const context: ShopContext = { conversationId, customer: { id: 2, name: 'Alex Rivera', … }, token: '<jwt>' };
```
Tools can read `context`, but the **model never sees it**. Identity lives here, not in the prompt, so a prompt like "show orders for customer 7" can't change who the tools act for.

### Step 5: open the user's own MCP connection
```ts
const account = await openAccountServer(context.token);   // mcp.ts
```
A **new** MCP connection to `<gateway>/mcp/account`, carrying `Authorization: Bearer <Alex's JWT>`. It's closed in `finally` after the run.

### Step 6: build the agent (`agent.ts`)
```ts
new Agent<ShopContext>({
  name: 'TrailForge Assistant',
  model: CHAT_MODEL,                         // 'gpt-5-mini' = your Azure DEPLOYMENT name
  instructions,                              // a FUNCTION: different text for guests vs logged-in users
  tools: [searchCatalog, searchKnowledge],   // local function tools → RAG
  mcpServers: [catalog, promotions, account] // remote tools from the store
});
```

### Step 7: run it: the **agent loop** (`run()` from the Agents SDK)
```ts
const stream = await run(assistant, input, {
  stream: true, context, session: new PostgresSession(db, conv.id), maxTurns: 12, signal: abort.signal,
});
```
What the SDK does inside `run()`:
```
a. session.getItems()              → load earlier messages of this conversation from Postgres
b. list tools                      → our 2 function tools + MCP tools (tools/list on each MCP connection,
                                     catalog filtered to get_product/check_stock/get_reviews)
c. CALL THE MODEL (Azure OpenAI)   → instructions + history + new message + tool definitions
d. model replies with TOOL CALLS   → get_my_orders {} · search_knowledge {"query":"GPS watch return window"}
e. SDK EXECUTES them               → get_my_orders → MCP tools/call over HTTP (§7)
                                     search_knowledge → our execute() → Azure AI Search (§9)
f. results go back to the model    → it may call more tools (get_order_details …) → repeat c–f
g. model replies with FINAL TEXT   → streamed token by token
h. session.addItems(newItems)      → save the user message, tool calls, results and answer
```
`maxTurns: 12` stops a runaway loop. `signal` stops it when the browser disconnects.

### Step 8: turn SDK events into SSE for the browser (`forward()` in `index.ts`)
| SDK stream event | SSE sent | Browser shows |
|---|---|---|
| `raw_model_stream_event` with `output_text_delta` | `delta` | text appearing |
| `run_item_stream_event` / `tool_called` | `tool_call` | a tool card "search_knowledge…" |
| `run_item_stream_event` / `tool_output` | `tool_result` (+ `auth_required` if the output contains `AUTH_REQUIRED`) | tool result / Log in button |
| `agent_updated_stream_event` | `agent` | agent name (after handoffs, Phase 7) |
| run finished | `done` with token usage | "12 000 in · 600 out · 3 model calls" |

### Step 9: clean up
`finally { await account.close(); res.end(); }`

## 7. How MCP calls work (the store's tools)

### 7.1 The client side (assistant, `mcp.ts`)
```ts
// shared, opened once at startup (dropFailed: a server that's down is skipped, retried every 30 s)
new MCPServerStreamableHttp({ name: 'catalog', url: `${STORE_MCP_BASE_URL}/catalog`,
  toolFilter: createMCPToolStaticFilter({ allowed: ['get_product', 'check_stock', 'get_reviews'] }) });
new MCPServerStreamableHttp({ name: 'promotions', url: `${STORE_MCP_BASE_URL}/promotions` });

// per request, as the user
new MCPServerStreamableHttp({ name: 'account', url: `${STORE_MCP_BASE_URL}/account`,
  requestInit: { headers: { Authorization: `Bearer ${userJwt}` } } });
```
`STORE_MCP_BASE_URL` is the **public gateway** (`http://localhost:3000/mcp`), never internal addresses.

### 7.2 On the wire
When the model calls `get_my_orders`, the SDK sends one JSON-RPC message:
```http
POST http://localhost:3000/mcp/account
Authorization: Bearer <Alex's JWT>
Content-Type: application/json
Accept: application/json, text/event-stream

{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_my_orders","arguments":{}}}
```
The gateway relays it (adding `x-mcp-key`) to `mcp-account :4203`, which answers:
```
event: message
data: {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"[{\"number\":\"TF-100099\",\"status\":\"on_the_way\",…}]"}]}}
```

### 7.3 The server side (`packages/mcp-kit` + `services/mcp-account`)
```ts
app.post('/mcp', serviceKey, async (req, res) => {             // serviceKey: x-mcp-key must match
  const server = buildServer({ userToken: <Bearer token or null> });  // NEW server per request
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined }); // stateless
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);            // SDK parses JSON-RPC, calls the tool
});
```
Inside `mcp-account`, every tool runs **as that user**:
```ts
async () => asUser('their orders', (t) => services.order('/me/orders', { token: t }), json)
//          ↑ no token → "AUTH_REQUIRED: …"   ↑ calls the order SERVICE with the user's JWT (store side)
```
So the chain is: **model → SDK → MCP client → gateway → MCP server → order service → Postgres**. The order service verifies the JWT, as in Trace 1.

**Why a new server per request ("stateless")?** Nothing is kept between requests, so any copy of the MCP server can answer any call (easy scaling), and the user's token naturally belongs to exactly one request.

## 8. How the assistant calls Azure OpenAI (`openai.ts`)

```ts
const baseURL = `${AZURE_OPENAI_ENDPOINT}/openai/v1/`;        // Azure's OpenAI-compatible endpoint
const apiKey  = AZURE_OPENAI_API_KEY
  || getBearerTokenProvider(new DefaultAzureCredential(), 'https://cognitiveservices.azure.com/.default');
const client  = new OpenAI({ baseURL, apiKey });
setDefaultOpenAIClient(client);                                // the Agents SDK now uses Azure
```
- **The same `openai` package** talks to Azure; only the URL and the credential change.
- **No key in `.env`?** `DefaultAzureCredential` finds a login automatically: your `az login` locally, the Managed Identity on Azure. `getBearerTokenProvider` returns a *function*. The SDK calls it before each request to get a fresh token (≈1 hour lifetime), sent as `Authorization: Bearer <entra token>`.
- **`model: 'gpt-5-mini'`** is the Azure **deployment name**.
- Each agent turn is roughly `POST <endpoint>/openai/v1/responses` with the instructions, history, tool schemas and `stream: true`. Azure checks the token, your role (*Cognitive Services OpenAI User*) and the quota, then streams back.
- Embeddings (for RAG) use the same client: `client.embeddings.create({ model: 'text-embedding-3-small', input })` → 1536 numbers.

## 9. How the assistant calls Azure AI Search: RAG (`rag.ts`)

### 9.1 Setup
```ts
const credential = AZURE_SEARCH_API_KEY ? new AzureKeyCredential(key) : new DefaultAzureCredential();
const search    = new SearchClient(AZURE_SEARCH_ENDPOINT, 'tf-rag', credential);  // ONE index:
// every chunk has type = 'product' | 'knowledge'; search_catalog filters type eq 'product',
// search_knowledge filters type eq 'knowledge', so the two never mix.
const embedder  = createOpenAIClient(ai.embeddings);   // Azure OpenAI, for query embeddings
```

### 9.2 What one `search_knowledge` call does
```ts
// 1. embed the question (same model the index was built with)
const vector = (await embedder.embeddings.create({ model: 'text-embedding-3-small', input: query })).data[0].embedding;

// 2. HYBRID search: keywords + vector, then the semantic re-ranker
await search.search(query, {
  top: 5,
  filter: "type eq 'knowledge'",
  select: ['id','source','title','section','chunkIndex','content'],          // only fields this index has
  vectorSearchOptions: { queries: [{ kind: 'vector', vector, fields: ['contentVector'], kNearestNeighborsCount: 50 }] },
  queryType: 'semantic', semanticSearchOptions: { configurationName: 'semantic' },
});

// 3. format passages with citation ids for the model
"[returns-and-refunds.md#1] Returns and Refunds Policy › The return window\n- Electronics … 30 days …"
```
The SDK turns that into `POST https://<search>.search.windows.net/indexes/tf-rag/docs/search?api-version=…` with an Entra token (your **Search Index Data Contributor** role locally; the Managed Identity on Azure). Azure AI Search runs BM25 keyword ranking and HNSW vector nearest-neighbours, fuses them with **RRF**, and re-ranks with the semantic model.

### 9.3 `search_catalog` adds filters and counts
- **Filters** (OData) built from tool arguments, always starting with the type: `type eq 'product' and category eq 'tents' and priceCents le 40000 and tags/any(t: t eq 'vegan')`.
- **Dedupe:** each product has about 5 chunks; keep the best chunk per `slug`.
- **"List all products":** a second query `search('*', { top: 0, facets: ['category'], filter: 'chunkIndex eq 0' })` counts **one chunk per product**, so the counts are products (12 per category), not chunks.
- **Fallbacks:** no `AZURE_SEARCH_ENDPOINT` → `SEARCH_UNAVAILABLE` (the agent says search is unavailable instead of guessing). Semantic ranker not available → plain hybrid.

### 9.4 Where the index came from (`scripts/rag/src/ingest.ts`)
Offline, not at chat time: read `rag/products/*.md` (type `product`) and `rag/knowledge/*.md` (type `knowledge`) → split on `##` headings (~900 chars, 150 overlap) → embed in batches of 16 with Azure OpenAI → `createOrUpdateIndex(schema)` → `mergeOrUploadDocuments` in batches of 500, all into the one `tf-rag` index.

## 10. All the credentials in one table

| Credential | Header / mechanism | From → to | Checked by |
|---|---|---|---|
| **User JWT** | `Authorization: Bearer <jwt>` | browser → gateway → services; assistant → gateway `/mcp/account` → mcp-account → services | every service's `authenticate` (`JWT_SECRET`) |
| **Internal token** | `x-internal-token` | store service → store service | `authenticate` → `requireInternal` |
| **MCP key** | `x-mcp-key` | gateway → MCP servers | `mcp-kit` `serviceKey` (if `MCP_AUTH_TOKEN` set) |
| **Entra ID token** | `Authorization: Bearer <entra>` via `DefaultAzureCredential` | assistant / ingest → Azure OpenAI, Azure AI Search | Azure (RBAC roles) |

## 11. When things fail

| Failure | What the code does |
|---|---|
| A service is down | `serviceClient` → `503 SERVICE_UNAVAILABLE`; gateway returns it to the browser |
| A downstream error (e.g. card declined `402`) | Re-thrown with the same status/code all the way up |
| Payment fails mid-checkout | Saga compensation: release the reservation, mark the order cancelled |
| Non-critical side effect fails | `Promise.allSettled` → logged, the order still succeeds |
| An MCP server is down | `dropFailed`: the agent runs without those tools and says that part is unavailable; retried every 30 s |
| Guest asks for orders | mcp-account answers `AUTH_REQUIRED` → `auth_required` SSE → Log in button |
| Search not configured | `SEARCH_UNAVAILABLE` → the agent doesn't guess |
| User closes the tab | Gateway aborts → assistant `signal` aborts the run |
| Model loops on tools | `maxTurns: 12` stops it |

## 12. Read the code in this order

1. `packages/shared/src/http.ts`, `auth.ts`, `client.ts`, `errors.ts`, `db.ts`: the toolkit (§2).
2. `services/catalog/src/index.ts`: a simple service with read routes.
3. `services/gateway/src/index.ts`: `forward()`, aggregation, `proxyStream`, `/mcp/:server` (§3).
4. `services/order/src/index.ts`: the checkout saga, returns, stages (§4).
5. `services/assistant/src/index.ts` → `agent.ts` → `openai.ts` → `rag.ts` → `mcp.ts` → `session.ts` (§5–9).
6. `packages/mcp-kit/src/index.ts` → `services/mcp-account/src/index.ts` (§7).
7. `scripts/rag/src/ingest.ts` (§9.4).

## 13. Exercises (to make it stick)

1. **Watch a request travel:** run `npm run dev`, open "My orders" in the store, and find the matching `GET /api/me/orders` line in the gateway log and `GET /me/orders` in the order log.
2. **Call a service directly:** `curl localhost:4002/products?q=tent` (the catalog, bypassing the gateway). Then `curl localhost:4004/me/orders` without a token → 401. Why?
3. **Speak MCP:** `npm run mcp:cli -- --server account --method tools/call --tool-name get_my_orders` → `AUTH_REQUIRED`. Then add `--header "Authorization: Bearer <token>"` (see the MCP guide).
4. **See the agent loop:** in `services/assistant/src/index.ts` → `forward()`, add `console.log(event.type, event.name)` and send one chat message. Count the model calls and tool calls.
5. **Query RAG yourself:** in Azure portal → `tf-rag` → Search explorer, search `GPS watch return` (JSON view: add `"filter": "type eq 'knowledge'"`), and compare with what `search_knowledge` returned in the chat tool card.
6. **Break it on purpose:** stop `mcp-catalog`, ask "is the Ridgeline tent in stock?" and see how the assistant degrades.

## 14. Glossary

| Term | Meaning here |
|---|---|
| **BFF / gateway** | Backend-for-frontend: one public API in front of many services |
| **Saga** | A multi-service operation with compensating steps instead of one big transaction |
| **SSE** | Server-Sent Events: one long HTTP response carrying many small events |
| **JWT** | Signed token saying who the user is; verified with `JWT_SECRET` |
| **RunContext** | Per-run data for tools and instructions, never sent to the model |
| **Session** | Where the Agents SDK loads and saves conversation history (`PostgresSession`) |
| **Function tool** | A tool implemented in the assistant's own code (`search_catalog`) |
| **MCP tool** | A tool implemented by another process, called via JSON-RPC over HTTP |
| **Hybrid search** | Keyword (BM25) + vector similarity, fused with RRF |
| **Embedding** | 1536 numbers representing the meaning of a text |
| **DefaultAzureCredential** | Finds an Azure login automatically (az login / Managed Identity) |

Related: [Architecture & Contracts](architecture.md) · [MCP Guide](mcp-guide.md) · [Azure OpenAI Setup](azure-openai-setup.md) · [Azure AI Search for RAG](azure-ai-search-rag-setup.md) · [Monorepo Guide](monorepo-guide.md)
