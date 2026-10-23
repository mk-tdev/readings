# TrailForge: Architecture & Contracts

This is the source of truth for ports, data shapes and the public API. Frontend, services and the assistant all build against it.

## Ports

| Component | Port | Package |
|---|---|---|
| PostgreSQL | 5432 | docker `trailforge-postgres` (user/pass `trailforge`) |
| pgAdmin | 5050 | http://localhost:5050 |
| gateway (BFF) | 3000 | `@tf/gateway` |
| customer | 4001 | `@tf/customer` → db `tf_customer` |
| catalog | 4002 | `@tf/catalog` → db `tf_catalog` |
| inventory | 4003 | `@tf/inventory` → db `tf_inventory` |
| order | 4004 | `@tf/order` → db `tf_order` |
| payment | 4005 | `@tf/payment` → db `tf_payment` |
| promotion | 4006 | `@tf/promotion` → db `tf_promotion` |
| marketing | 4007 | `@tf/marketing` → db `tf_marketing` |
| assistant | 4100 | `@tf/assistant` → db `tf_assistant` |
| mcp-catalog | 4201 | `@tf/mcp-catalog`: MCP server (Streamable HTTP, stateless) over the catalog REST API, no database |
| mcp-promotions | 4202 | `@tf/mcp-promotions`: MCP server over the promotion REST API (public promotions only), no database |
| mcp-account | 4203 | `@tf/mcp-account`: per-user MCP server (user JWT in `Authorization`) over order/customer/promotion APIs, no database |
| web (storefront + admin) | 5173 | `@tf/web`: **Next.js 16**. `app/api/[...path]` route handler proxies to the gateway and adds the cookie token. |
| chat (full-screen) | 5174 | `@tf/chat`: **React + Vite**. The Vite dev proxy forwards `/api` → 3000. |

## Conventions

- **Money is integer cents** everywhere (`priceCents`, `totalCents`). Currency is USD.
- **IDs:** `bigint` identity columns, serialized as numbers. Orders also have a human `number` (e.g. `TF-100042`).
- **JSON is camelCase** over HTTP; **snake_case** in SQL.
- **Errors:** `{ "error": { "code": "NOT_FOUND", "message": "..." } }` with a matching HTTP status.
- **Auth:**
  - The customer service issues an HS256 JWT (`sub` = customer id, `role` = `customer|admin`, `email`, `name`).
  - Browsers send `Authorization: Bearer <token>`; the gateway forwards it, and every service verifies it with the shared `JWT_SECRET`.
  - Service-to-service calls send `x-internal-token: $INTERNAL_TOKEN` (trusted, may act on any customer).
- Token storage:
  - **web (Next.js):** httpOnly cookie `tf_token`, set by `POST /api/session`; browser JavaScript never sees the JWT.
  - **chat (Vite):** `localStorage["tf_token"]`, the simpler SPA approach. Compare the two trade-offs.

## Public API (gateway, `/api/*`)

### Auth & profile
| Method | Path | Body / query | Response |
|---|---|---|---|
| POST | `/api/auth/register` | `{ email, password, firstName, lastName }` | `{ token, customer }` |
| POST | `/api/auth/login` | `{ email, password }` | `{ token, customer }` |
| GET | `/api/me` 🔒 | | `Customer` |
| PATCH | `/api/me` 🔒 | `{ firstName?, lastName?, phone?, marketingOptIn? }` | `Customer` |
| GET | `/api/me/addresses` 🔒 | | `Address[]` |
| POST | `/api/me/addresses` 🔒 | `Address` without id | `Address` |

```ts
type Customer = { id: number; email: string; firstName: string; lastName: string; phone: string | null;
  role: 'customer' | 'admin'; tier: 'bronze' | 'silver' | 'gold'; points: number; birthday: string | null;
  marketingOptIn: boolean; createdAt: string };
type Address = { id: number; label: string; line1: string; line2: string | null; city: string; state: string;
  postalCode: string; country: string; isDefault: boolean };
```

### Catalog
| Method | Path | Notes |
|---|---|---|
| GET | `/api/categories` | `Category[]` = `{ slug, name, description, productCount }` |
| GET | `/api/products` | query `q, category, brand, minPrice, maxPrice (cents), sort (relevance\|price_asc\|price_desc\|rating\|newest), page (1-based), pageSize (≤48)` → `{ items: ProductSummary[], total, page, pageSize }` |
| GET | `/api/products/:slug` | `Product` |
| GET | `/api/products/:slug/reviews` | `Review[]` |

```ts
type ProductSummary = { id: number; slug: string; name: string; brand: string; category: string;
  priceCents: number; rating: number; reviewCount: number; inStock: boolean; tags: string[] };
type Product = ProductSummary & { description: string; highlights: string[]; specs: Record<string, string>;
  useCases: string[]; warrantyYears: number; variants: Variant[] };
type Variant = { id: number; sku: string; size: string | null; color: string | null; priceCents: number; stock: number };
type Review = { id: number; rating: number; title: string; body: string; authorName: string; createdAt: string };
```

### Cart & checkout
The cart lives in the browser (`localStorage["tf_cart"]` = `{ variantId, qty }[]`); the server prices it.

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/api/cart/quote` | `{ items: {variantId, qty}[], promoCode? }` | `Quote` |
| POST | `/api/orders` 🔒 | `{ items, promoCode?, addressId, payment: { cardNumber, expiry, cvc } }` | `Order` |

```ts
type QuoteLine = { variantId: number; productSlug: string; name: string; size: string | null; color: string | null;
  qty: number; unitPriceCents: number; lineTotalCents: number; available: number };
type Quote = { lines: QuoteLine[]; subtotalCents: number; discountCents: number; shippingCents: number;
  taxCents: number; totalCents: number; promotion: { code: string; title: string } | null; messages: string[] };
```
Shipping: free over $75 subtotal, otherwise $7.95. Tax: 8% of (subtotal − discount). Test card `4242 4242 4242 4242` succeeds; `4000 0000 0000 0002` is declined.

### Orders
| Method | Path | Response |
|---|---|---|
| GET | `/api/me/orders` 🔒 | `OrderSummary[]` = `{ number, status, placedAt, totalCents, itemCount }` |
| GET | `/api/me/orders/:number` 🔒 | `Order` |
| POST | `/api/me/orders/:number/cancel` 🔒 | `Order` (only while `pending`/`preparing`) |
| POST | `/api/me/orders/:number/returns` 🔒 | body `{ items: {orderItemId, qty}[], reason }` → `Return` |

```ts
// pending = checkout saga running. After placement: preparing → on_the_way → delivered.
type OrderStatus = 'pending' | 'preparing' | 'on_the_way' | 'delivered' | 'cancelled' | 'returned' | 'partially_returned';
type Order = { id: number; number: string; customerId: number; status: OrderStatus; placedAt: string;
  subtotalCents: number; discountCents: number; shippingCents: number; taxCents: number; totalCents: number;
  promoCode: string | null; shippingAddress: Address;
  items: { id: number; variantId: number; sku: string; productSlug: string; name: string; size: string | null;
           color: string | null; qty: number; unitPriceCents: number }[];
  shipments: { carrier: string; trackingNumber: string; status: string; shippedAt: string; deliveredAt: string | null }[];
  returns: Return[] };
type Return = { id: number; status: 'requested' | 'approved' | 'rejected' | 'refunded'; reason: string;
  refundCents: number; createdAt: string; items: { orderItemId: number; qty: number }[] };
```

### Promotions & marketing
| Method | Path | Response |
|---|---|---|
| GET | `/api/promotions` | active public `Promotion[]` |
| GET | `/api/me/offers` 🔒 | `Promotion[]` personal offers the customer is eligible for (public + targeted) |
| GET | `/api/me/messages` 🔒 | `Message[]` = `{ id, subject, body, createdAt, readAt }` |

```ts
type Promotion = { id: number; code: string; title: string; description: string; audience: 'public' | 'targeted';
  type: 'percent' | 'fixed' | 'free_shipping'; value: number; minSubtotalCents: number | null;
  categories: string[] | null; startsAt: string; endsAt: string | null };
```

### Extra customer routes
`GET /api/me/loyalty` (tier, points, recent events) · `GET /api/me/summary` (aggregated: profile + 3 recent orders + offers, an example of BFF aggregation) · `POST /api/me/messages/:id/read`

### Dev-only: quick account switching
On when `NODE_ENV !== 'production'`; set `DEV_QUICK_LOGIN=false` to turn it off. The flag is checked in the customer service, which returns 404 when it's off.
| Method | Path | Notes |
|---|---|---|
| GET | `/api/dev/accounts` | every account + `orderCount`, `lastOrderAt`, `segments` (gateway aggregates customer + order + marketing) |
| POST | `/api/dev/login-as` | `{ customerId }` → `{ token, customer }`: impersonation, no password |

The web app uses it through `POST /api/session { mode: 'dev', customerId }`, so the token still lands only in the httpOnly cookie. UI: the **Switch test account** modal on `/login` (`apps/web/components/QuickLogin.tsx`).

### Admin 🔒(role=admin)
| Route | Notes |
|---|---|
| `GET /api/admin/orders?status=&customerId=` | all customers' orders + `customerName/Email/Tier` (gateway joins order + customer) |
| `GET /api/admin/orders/summary` | `{ orders, customers, revenueCents, last7Days, byStatus: { preparing: {count,totalCents}, … } }` |
| `GET /api/admin/orders/:number` · `POST /api/admin/orders/:number/advance` | any order; advance = preparing → on_the_way (creates shipment + tracking) → delivered (stamps delivery). Each step writes `order_status_history` and an inbox message |
| `GET /api/admin/inventory` | every variant: `onHand, reserved, available, reorderPoint, sold30d, lastMovement` + product name (gateway joins inventory + catalog) |
| `POST /api/admin/inventory/restock` | `{ variantId, qty }` → logs a `restock:admin:<id>` movement |
| `GET /api/admin/returns?status=requested` · `POST /api/admin/returns/:id/decide` `{decision}` | refund review |
| `GET /api/admin/customers` | with tier/points |
| `GET /api/admin/inventory/low-stock` | `{ variantId, sku, onHand, reserved, available, reorderPoint }` |
| `GET /api/admin/segments` · `/campaigns` · `/promotions` | marketing + promotion views |
| `GET /api/admin/approvals` | `{ id, kind, summary, orderNumber?, amountCents?, createdAt }[]`; ids look like `return-18` or `run-3` |
| `POST /api/admin/approvals/:id` | `{ decision: 'approve' \| 'reject' }` |

## Order lifecycle & inventory
```
checkout:  pending ──(reserve stock → charge card → commit stock)──► preparing
           pending ──(any step fails: release stock)──► cancelled
admin:     preparing ──► on_the_way ──► delivered        (POST /api/admin/orders/:n/advance)
customer:  preparing ──cancel──► cancelled  (refund + restock)
returns:   delivered ──► partially_returned / returned   (refund + restock)
```
Inventory `on_hand` drops when the reservation is committed at checkout and goes back up on cancel or return. Every change is a row in `movements` (`sale:<order>`, `cancel:<order>`, `return:<order>`, `restock:…`). Order `Order.statusHistory` = `{ status, note, changedBy, createdAt }[]`.

## Return & refund policy (enforced in `services/order`, constants `RETURN_POLICY` in `packages/shared/src/types.ts`)
- Window: 60 days from delivery; `navigation-electronics` 30 days.
- Non-returnable online: products tagged `safety-gear` (harnesses, ropes, carabiners, belay devices, helmets, via ferrata) or `final-sale` (gift cards). Tags come from the catalog at check time.
- Refund = what was paid: `itemPrice × qty × (subtotal − discount + tax) ÷ subtotal`. Shipping is refunded only on cancellation.
- ≤ $100 → approved automatically (`decided_by = 'auto'`). Larger → `requested`, shown in admin approvals.
- `POST /me/orders/:n/returns/check` = dry run → `{ eligible, problems[], refundCents, autoApprove }`. The assistant will use this.
- Approval runs: payment refund (idempotency key `return:<id>`) → inventory restock → order status (+history) → loyalty reversal → inbox message.
- Cancellation (only `preparing`): full refund (`cancel:<n>`) → restock → promo redemption deleted (one-use codes come back) → loyalty reversal → inbox.
- Customer-facing source of truth for RAG: `rag/knowledge/refund-policy.md`, `returns-and-refunds.md`, `order-cancellation-and-changes.md`, `delivery-and-order-status.md`, `damaged-defective-lost-or-wrong-items.md`, `store-policies-overview.md`.

## Test data (`npm run db:reset`)
| Account | Password | Notes |
|---|---|---|
| `demo@trailforge.example` (Alex Rivera) | `Password123!` | Gold. Has edge-case orders: delivered 14d ago (expensive, so the refund needs approval), delivered 24d ago (cheap, auto-refund), delivered 79d ago (outside the window), shipped (in transit), processing (cancellable), plus older orders. Birthday this month, so BDAY20 applies. |
| `admin@trailforge.example` | `Admin123!` | Admin console |
| 29 more customers `<first>.<last><n>@example.com` | `Password123!` | Personas: heavy, regular, occasional, lapsed, none (no orders, so WELCOME10 applies) |


### Chat (assistant via gateway)
`POST /api/chat` with body `{ conversationId?: string, message: string }` and an optional `Authorization` header. The response is `text/event-stream` with these events:

| event | data |
|---|---|
| `meta` | `{ conversationId, authenticated: boolean, customerName?: string }` |
| `delta` | `{ text }` (append to the assistant message) |
| `agent` | `{ name }` (active agent changed, e.g. after a handoff) |
| `tool_call` | `{ id, name, arguments }` |
| `tool_result` | `{ id, output }` |
| `auth_required` | `{ reason }` (UI shows a "Log in" button inside the chat) |
| `approval_required` | `{ id, summary }` (human approval pending) |
| `done` | `{ usage?: { inputTokens, outputTokens, requests } }` |
| `error` | `{ message }` |

`GET /api/chat/:conversationId/messages` returns the conversation history `{ role: 'user' | 'assistant', text }[]`, which lets the UI restore a conversation after login.

## AI app ↔ store boundary (the most important rule)

The assistant is a **separate application** owned by another team. It reaches the store **only through MCP**, published by the store's public gateway at `/mcp/<name>`, plus its **own RAG indexes** (Azure AI Search). It makes **no** calls to store service APIs (`services/assistant` has no `services.*` calls).

| Need | Source |
|---|---|
| Find/list/compare products, specs | RAG `search_catalog` (`tf-rag`, `type eq 'product'`) |
| Policies, guides, FAQs | RAG `search_knowledge` (`tf-rag`, `type eq 'knowledge'`) |
| Live stock / exact price / reviews | MCP catalog, filtered to `get_product`, `check_stock`, `get_reviews` |
| Public promotions, code checks | MCP promotions |
| The user's orders, offers, profile, return eligibility | MCP account, per-request connection with the user's JWT |

## MCP servers

All are built on `@tf/mcp-kit` (`packages/mcp-kit`): Streamable HTTP at `POST /mcp`, **stateless** (a new server per request), `/healthz`, bound to `127.0.0.1` locally (DNS-rebinding protection) or `MCP_HOST=0.0.0.0` in containers. Two headers:
- `Authorization: Bearer <user JWT>` → `buildServer({ userToken })` (per-user tools; services verify it);
- `x-mcp-key: $MCP_AUTH_TOKEN` → required when set, added by the gateway, so only the gateway can reach the servers.

They call service REST APIs (they belong to the e-commerce side); they never read a database.

| Server | Tools | Resources | Prompts |
|---|---|---|---|
| **mcp-catalog** `:4201` | `search_products` · `get_product` · `check_stock` (`structuredContent`) · `get_reviews` · `list_categories` | `catalog://categories` · template `catalog://products/{slug}` | `compare_products` |
| **mcp-promotions** `:4202` | `list_public_promotions` · `check_promo_code` · `get_promotion_terms` | `promotions://active` | `find_best_deal` |
| **mcp-account** `:4203` | `get_my_profile` · `get_my_orders` · `get_order_details` · `get_my_offers` · `check_return_eligibility` (dry run). Guests → `AUTH_REQUIRED` | | |

**Gateway** (`services/gateway`): `ALL /mcp/:server` (`catalog`, `promotions`, `account`) → internal `MCP_*_URL`; passes `content-type`, `accept`, `authorization`, MCP protocol headers; adds `x-mcp-key`; streams the response.

**Assistant** (`services/assistant/src/mcp.ts`, `agent.ts`, `rag.ts`):
- Shared connections (opened once, `dropFailed`, 30 s retry) to `STORE_MCP_BASE_URL/catalog` (tool filter: `get_product`, `check_stock`, `get_reviews`) and `/promotions`.
- Per chat request: a new `account` connection with `Authorization: Bearer <user JWT>` (none for guests), closed after the run.
- Local tools: only `search_catalog`, `search_knowledge` (RAG). When search isn't configured they return `SEARCH_UNAVAILABLE`.
- A tool output containing `AUTH_REQUIRED` → one `auth_required` SSE event. When a guest conversation is adopted at login, a system note is added to that turn.
- `GET /api/admin/assistant/status` → `{ model, provider{…}, rag{ configured, endpoint, indexes, embeddings }, mcp: [{ name, connected, tools[], agentTools[] }] }`.
- **Approvals:** the assistant lists only its own paused runs (`run-*`); the gateway composes `/api/admin/approvals` from order-service refunds (`return-*`) + assistant runs, and routes decisions to the owner.

Checks: `npm run smoke:mcp` (27 checks: direct + through the gateway). Standalone: `npm run mcp:standalone` (the REST services MCP needs + all three MCP servers + MCP Inspector from `scripts/mcp/inspector.json`). CLI: `npm run mcp:cli -- --server catalog --method tools/list`.

## AI provider (`packages/shared/src/ai.ts`)
`MODEL_PROVIDER=azure|openai|auto` (auto: Azure if `AZURE_OPENAI_ENDPOINT`, else OpenAI if `OPENAI_API_KEY`). `EMBEDDING_PROVIDER` defaults to the chat provider; ingest and queries must use the same one. Models: `AZURE_OPENAI_CHAT_DEPLOYMENT` / `OPENAI_CHAT_MODEL`, `AZURE_OPENAI_EMBEDDING_DEPLOYMENT` / `OPENAI_EMBEDDING_MODEL`. Tracing to the OpenAI dashboard only when `OPENAI_AGENTS_DISABLE_TRACING=false` and `OPENAI_API_KEY` is set.

## Seed source data formats

`data/products.json`:
```jsonc
{
  "categories": [{ "slug": "tents", "name": "Tents & Shelters", "description": "..." }],
  "products": [{
    "sku": "TF-TEN-001", "slug": "ridgeline-2p-ultralight-tent", "name": "Ridgeline 2P Ultralight Tent",
    "brand": "TrailForge", "category": "tents", "priceCents": 34900,
    "description": "2–3 paragraphs", "highlights": ["..."],
    "specs": { "Weight": "1.6 kg", "Capacity": "2 person", "Waterproof rating": "3000 mm" },
    "useCases": ["backpacking", "3-season"], "tags": ["ultralight"], "warrantyYears": 2,
    "variants": [{ "sku": "TF-TEN-001-GRN", "size": null, "color": "Forest Green", "priceDeltaCents": 0 }]
  }]
}
```
`data/promotions.json`: see the file. The rule fields are interpreted by the promotion service.
