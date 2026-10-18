# TrailForge: Implementation Plan

> A full-stack outdoor & hiking gear store built as microservices, with an agentic AI assistant made only with the **OpenAI Agents SDK (JS)**, with no orchestration framework. Learning project: every concept is implemented "raw" so you can see how it works.
>
> **Status legend:** ✅ done · 🟡 in progress / partly done · ⬜ not started · 🔒 blocked (needs Azure)
> **Last updated:** 2026-10-17 · See also [Deployment Plan](deployment-plan.md), [Architecture & Contracts](architecture.md), [Application Context](application-context.md), [Monorepo Guide](monorepo-guide.md), [MCP Guide](mcp-guide.md), [Azure OpenAI Setup](azure-openai-setup.md), [Azure AI Search for RAG](azure-ai-search-rag-setup.md), [RAG in the Azure Portal](azure-ai-search-portal-rag.md), [Backend Walkthrough](backend-walkthrough.md)

## 1. Goals

- A realistic e-commerce platform: browse, search, cart, checkout, register/login, order history, order tracking, returns, promotions, loyalty, plus an admin console.
- **Each business capability is its own microservice with its own PostgreSQL database.**
- An **AI assistant** that:
  - answers product, policy and promotion questions with **Agentic RAG** over **Azure AI Search**;
  - knows whether the visitor is logged in, and asks them to log in for private questions ("where is my order?");
  - shows **personal promotions** for the logged-in customer and public ones for everyone;
  - runs **agentic workflows**: automated refunds, promo matching, campaign drafting, restock proposals;
  - is protected by layered **guardrails** (input, tool, RAG, output, human approval);
  - is a **standalone** package that is embedded in the store as a widget **and** served as a full-screen chat app.
- Repeatable test data: `npm run db:reset` scrubs and recreates everything (30 users, 100 orders).
- Uses every core concept from https://openai.github.io/openai-agents-js/.
- Deployable: **Next.js storefront on Vercel**, **everything else on Azure**.

## 2. Architecture

```
 apps/web   (Next.js storefront + admin) :5173 ─┐  Server Components + BFF route handler (httpOnly cookie)
 apps/chat  (React + Vite full-screen)   :5174 ─┤  both embed packages/chat-ui
                                                │  REST + SSE
                                                ▼
 ┌──────────────────── services/gateway (BFF) :3000 ────────────────────┐
 │  /api/* → routes to services, verifies JWT, aggregates, proxies chat   │
 └──┬───────┬────────┬────────┬────────┬─────────┬─────────┬────────┬────┘
    ▼       ▼        ▼        ▼        ▼         ▼         ▼        ▼
 customer catalog inventory order  payment  promotion marketing  assistant
  :4001   :4002    :4003    :4004   :4005    :4006     :4007     :4100
    │       │        │        │        │         │         │        │  Agents SDK
    ▼       ▼        ▼        ▼        ▼         ▼         ▼        ▼
 tf_customer tf_catalog tf_inventory tf_order tf_payment tf_promotion tf_marketing tf_assistant
 └──────── one PostgreSQL 17 server (Docker locally, Azure Flexible Server in the cloud) ────────┘

 assistant ──► Azure OpenAI (chat + embeddings)
           ──► Azure AI Search (indexes: tf-products, tf-knowledge)
           ──► MCP servers (public catalog / promotions), Streamable HTTP
           ──► services REST (private data, with the user's JWT)
```

### Design rules (the important lessons)
| Rule | Why |
|---|---|
| Database per service; no cross-database joins | Real microservice boundary. Services talk over HTTP APIs. |
| Orders store a snapshot of product name/price | Orders must not change when the catalog changes. |
| Identity comes from the verified JWT → Agents SDK `RunContext` | The LLM never decides *who* the user is, so prompt injection can't read another customer's data. |
| **Services authorize every call themselves** | This is the real security boundary. LLM guardrails are defence in depth on top of it. |
| **The AI app reaches the store only via MCP (through the public gateway) + its own RAG** | The store is another team's system; the assistant never calls store APIs. Per-user data uses a per-request MCP connection carrying the user's JWT. |
| Products and knowledge from RAG (Azure AI Search); live stock/price/orders from MCP | Discovery from the AI app's own index; the store stays the source of truth for live data. |
| Workflows orchestrated in plain TypeScript; agents only where judgment is needed | Deterministic, testable, auditable. No framework magic. |
| Money-moving actions need policy checks, and above $100 a human | Refunds are deterministic rules first, the model second. |

## 3. Monorepo layout

```
trailforge/
├── research/                 # plans + design docs (md + generated html)
├── docker-compose.yml        # local postgres + pgadmin
├── packages/
│   ├── shared/               # config, db pool, migrations, http helpers, auth, service client, pricing, segments, policy constants
│   ├── mcp-kit/              # shared MCP host (Streamable HTTP, stateless) + result helpers
│   └── chat-ui/              # React chat components: <ChatWidget/> and <ChatPage/>
├── services/
│   ├── gateway/              # BFF :3000
│   ├── customer/             # auth, profile, addresses, loyalty, dev quick-login
│   ├── catalog/              # products, variants, categories, reviews
│   ├── inventory/            # stock, reservations, movements
│   ├── order/                # orders, stages, items, shipments, returns, status history
│   ├── payment/              # simulated payment provider: charges + refunds
│   ├── promotion/            # promotions, rules, eligibility, redemptions
│   ├── marketing/            # segments, campaigns, messages (inbox)
│   ├── assistant/            # OpenAI Agents SDK: agents, tools, guardrails, workflows, sessions
│   ├── mcp-catalog/          # MCP server :4201 over the catalog API (public)
│   ├── mcp-promotions/       # MCP server :4202 over the promotion API (public promotions)
│   └── mcp-account/          # MCP server :4203, per-user (orders, offers, profile, return check)
├── apps/
│   ├── web/                  # Next.js 16 (App Router) storefront + admin console  → Vercel
│   └── chat/                 # React + Vite standalone full-screen chat app        → Azure Static Web Apps
├── data/                     # seed source data (products.json, promotions.json)
├── rag/                      # knowledge/*.md (51 handwritten) + products/*.md (114 generated)
├── infra/                    # (Phase 11) Bicep for Azure + GitHub Actions workflows
└── scripts/
    ├── db/                   # reset / migrate / seed
    ├── rag/                  # prepare + ingest into Azure AI Search
    ├── smoke/                # API smoke test
    └── evals/                # (Phases 8 & 10) red-team + RAG quality evals
```

## 4. Services

| Service | Port | Database tables | Main endpoints |
|---|---|---|---|
| customer | 4001 | customers, addresses, loyalty_accounts, loyalty_events | register, login, me, addresses, loyalty, dev quick-login |
| catalog | 4002 | categories, products, variants, reviews | list/search, product detail, reviews, variant lookup |
| inventory | 4003 | stock_levels, reservations, movements | stock lookup, reserve, commit, release, restock, admin stock |
| order | 4004 | orders, order_items, shipments, returns, return_items, order_status_history | quote, checkout saga, my orders, cancel, returns (+dry-run check), admin stages |
| payment | 4005 | payments, refunds | charge, idempotent refund, list by order |
| promotion | 4006 | promotions, customer_offers, redemptions | public promos, my offers, validate code, redeem, release |
| marketing | 4007 | segments, customer_segments, campaigns, messages | segments, campaigns, inbox, notify |
| assistant | 4100 | conversations, conversation_items, pending_runs, traces, spans | chat (SSE), history, approvals |
| gateway | 3000 | none | `/api/*`, aggregation, SSE proxy |

## 5. Test data (scrub & recreate anytime)

`npm run db:reset` drops all `tf_*` databases → recreates → runs migrations → seeds. Deterministic (fixed faker seed):

- **30 customers** (+1 admin): password `Password123!`, mixed loyalty tiers, birthdays, addresses. A **Switch test account** modal on `/login` logs in as any of them (dev only).
- **114 products** across 10 categories with 527 size/color variants, specs and reviews.
- **100 orders** over the last 12 months across every stage (preparing, on the way, delivered, cancelled, returned, partially returned), each with status history. Includes deliberate edge cases on the demo account (refund over $100, auto-refund, outside the return window, in transit, cancellable).
- Payments for every order, refunds for returned/cancelled ones.
- **Public promotions + targeted offers** (VIP, birthday, lapsed customer, first order, campers).
- Marketing segments computed from order history.

## 6. Order lifecycle

```
checkout:  pending ─(reserve stock → charge card → commit stock)─► preparing
admin:     preparing ──► on_the_way (shipment + tracking) ──► delivered
customer:  preparing ──cancel──► cancelled        (refund + restock + promo code released)
returns:   delivered ──► partially_returned / returned   (refund = amount paid; ≤ $100 auto, else admin approval)
```

## 7. RAG data (Azure AI Search)

| Index | Source | Notes |
|---|---|---|
| `tf-products` | `rag/products/*.md`, generated from `data/products.json` | One doc per product, filterable category/brand/price/tags |
| `tf-knowledge` | `rag/knowledge/*.md` (51 docs) | Policies (refund, returns, cancellation, delivery & order status, damaged/lost, shipping, warranty, privacy, terms, overview), about, stores, loyalty, promotions, size/care/buying guides, FAQs |

Pipeline: `npm run rag:prepare` (render product docs) → `npm run rag:ingest` (chunk on headings → embed → upload). Never indexed: stock, prices, order data, customer reviews (user-generated = injection risk).

## 8. Chat behaviour

| Scenario | Behaviour |
|---|---|
| Anonymous: products, policies, public promos | Full answers (RAG + public tools) |
| Anonymous: "my orders", "my offers", refunds | Tool returns `AUTH_REQUIRED` → UI shows a **Log in** button in the chat → after login the same conversation continues |
| Logged in | Personalised dynamic instructions; private tools enabled (orders, profile, offers, refunds) |
| Logout mid-chat / another user | A new conversation starts; history is never shown to a different person |
| Guardrail trips | Friendly refusal or safe fallback message; the event is logged for the admin |

## 9. Agents, workflows & guardrails

**Multi-agent (LLM-orchestrated):** `Concierge` (triage) → handoffs to `Product Expert`, `Order Support`, `Deals`.

**Workflows (code-orchestrated):**
1. **Refund:** `/returns/check` rules → agent classifies the reason (structured output) → ≤ $100 auto-approve; larger ones pause with `needsApproval`, the serialized `RunState` is saved, an admin approves in the console and the run resumes → payment refund → restock → order update → inbox message.
2. **Promo matching:** profile + segments + cart fetched in parallel → promotion service decides eligibility → agent ranks and explains.
3. **Campaign drafter (admin):** segment → draft → output guardrail (no invented discounts) → approval → send.
4. **Restock proposals:** low-stock scan → agent proposes quantities → approval → restock.

**Guardrail layers:**

| Layer | SDK feature | TrailForge checks |
|---|---|---|
| ⓪ Service authorization | (not the SDK) JWT → RunContext, services verify | Customers only ever reach their own data |
| ① Input | `inputGuardrails` (`runInParallel: false` to block first) | Secrets/PII regex; small-model classifier for off-topic, jailbreak, other-customer fishing; Azure content filters / Prompt Shields |
| ② Tool input | `defineToolInputGuardrail` (`allow` / `rejectContent` / `throwException`), MCP `toolInputGuardrails` | Refund ≤ `/returns/check` amount; max 2 money actions per conversation; order-number format |
| ③ Human approval | `needsApproval` + interruptions + `RunState` | Refunds > $100, campaigns, restock |
| ④ Tool output (RAG) | `defineToolOutputGuardrail` | Relevance cutoff → "I don't know"; scan retrieved chunks for hidden instructions; record retrieved source ids in RunContext |
| ⑤ Output | `outputGuardrails` | Citations must be from this turn's retrieval; every $ amount / % / promo code must appear in tool outputs; optional grounding judge |

Streaming caveat: output guardrails run after the full answer, so high-stakes answers aren't streamed, and a tripwire on a streamed answer sends a `guardrail` SSE event that replaces it.

## 10. Agents SDK concept map

| Concept | Where | Status |
|---|---|---|
| Agent, instructions, modelSettings, `run`, agent loop, `maxTurns` | All agents | ✅ |
| Dynamic instructions (function) | Before/after login personalisation | ✅ |
| Function tools (zod), error handling | Public + private tools | ✅ |
| RunContext (local context) | customerId, role, JWT: never sent to the LLM | ✅ |
| Sessions (custom Postgres session) | Chat memory survives restarts and login | ✅ |
| Streaming events → SSE | Text deltas, tool calls, auth prompts (verified live) | ✅ (handoff events in Phase 7) |
| `isEnabled` on tools | Admin-only tools hidden from customers | ⬜ Phase 7 |
| MCP servers (Streamable HTTP), `connectMcpServers`, tool cache, **tool filter**, **per-request authenticated connection** | catalog (filtered), promotions, account (per user) via the gateway | ✅ (MCP tool guardrails in Phase 8) |
| Agents as tools (`asTool`) | Product Expert used from Deals | ⬜ Phase 7 |
| Handoffs (`handoff()`, inputFilter, onHandoff, inputType) | Concierge → specialists | ⬜ Phase 7 |
| Structured output (`outputType`) | Classifiers, refund decision, ranked offers, campaign draft | ⬜ Phases 7–9 |
| Input / output / tool guardrails | See §9 | ⬜ Phase 8 |
| Human-in-the-loop (`needsApproval`, interruptions, `RunState` serialize/resume) | Large refunds, campaigns, restock | ⬜ Phase 9 |
| Code vs LLM orchestration | Workflows vs handoffs | ⬜ Phase 9 |
| Tracing (custom processor, `withTrace`, custom spans) | Optional OpenAI dashboard tracing now (`OPENAI_AGENTS_DISABLE_TRACING=false`); Postgres processor + admin viewer in Phase 10 | 🟡 |
| Lifecycle hooks / run events | Audit log, token usage | ⬜ Phase 10 |
| Model providers / per-agent models | `MODEL_PROVIDER` switch (Azure OpenAI / OpenAI) ✅; per-agent providers for classifiers in Phase 8 | 🟡 |
| Realtime voice agents | "Talk to support" mic button | ⬜ Phase 12 (stretch) |

## 11. Tech stack

- Node.js 24, TypeScript, npm workspaces
- **Express 5** for every backend service, the gateway and the assistant
- zod, `pg` with **plain SQL** + SQL migration files (no ORM)
- Auth: JWT (`jose`), passwords hashed with Node's built-in `scrypt`
- **Web app: Next.js 16 (App Router)**, with Server Components, a catch-all Route Handler as BFF proxy, a `proxy.ts` route guard and auth in an httpOnly cookie → **Vercel**
- **Chat app: React 19 + Vite** SPA → **Azure Static Web Apps**
- `packages/chat-ui`: plain React components shared by both
- PostgreSQL 17 (Docker locally → **Azure Database for PostgreSQL Flexible Server**)
- **Azure:** OpenAI, AI Search, Container Apps, Container Registry, Key Vault, Managed Identity, Log Analytics / Application Insights

## 12. Phases

### Overview
| # | Phase | Outcome | Status |
|---|---|---|---|
| 1 | Scaffold: monorepo, Docker Postgres, shared lib, migrations | `docker compose up` + `npm run db:reset` | ✅ |
| 2 | Microservices REST APIs + seed (30 users, 100 orders) | Queryable data, smoke-tested | ✅ |
| 3 | Next.js storefront, admin console, auth, order stages | Working shop + admin | ✅ |
| 4 | Azure AI foundation + RAG data, ingest & eval set | Search returns good results | 🟡 Azure + both indexes live · eval set open |
| 5 | Assistant core: RAG tools, MCP servers, streaming chat | Pre-login Q&A with citations | ✅ verified live on Azure OpenAI + Azure AI Search |
| 6 | Login-aware chat & memory | Pre/post-login chat | ✅ verified live (session trimming still open) |
| 7 | Multi-agent: handoffs, agents as tools, structured output | Specialist agents | ⬜ |
| 8 | Guardrails & safety | Layered protection + red-team eval | ⬜ (8a can start now) |
| 9 | Agentic workflows + human-in-the-loop | Automated refunds, promos, campaigns, restock | ⬜ |
| 10 | Observability & evals | Trace viewer, audit log, quality metrics | ⬜ |
| 11 | Deployment: Azure + Vercel | Live on the internet | ⬜ (see [Deployment Plan](deployment-plan.md)) |
| 12 | Stretch: voice, extras | Realtime voice support | ⬜ |

### Phase 1: Scaffold ✅
- [x] npm workspaces monorepo, TypeScript project references
- [x] Docker Compose: Postgres 17 + pgAdmin, one database per service
- [x] `@tf/shared`: config, db helpers, migration runner, `createService`, errors, auth, service client
- [x] Research docs (plan, architecture) with an HTML renderer

### Phase 2: Microservices + seed ✅
- [x] 7 domain services + gateway on Express 5 with plain SQL migrations
- [x] Checkout saga (reserve → charge → commit, compensate on failure), idempotent refunds
- [x] Promotion eligibility rules, segments, loyalty tiers
- [x] Deterministic seed: 30 customers, 114 products, 100 orders, reviews, payments, returns
- [x] `npm run db:reset` scrub & recreate; API smoke test (21 checks)

### Phase 3: Storefront, admin, auth ✅
- [x] Next.js 16 App Router storefront (Server Components, catalog, product, cart, checkout)
- [x] httpOnly-cookie auth through a BFF route handler; `proxy.ts` route guard
- [x] Register / login, account, orders, returns, offers, inbox
- [x] Dev-only **Switch test account** modal (disabled in production)
- [x] Order stages **Preparing → On the way → Delivered** with status history and a customer tracker
- [x] Admin console: overview, all customers' orders with stage controls, full inventory with restock, customers, approvals, order detail
- [x] Refund = amount paid; safety-gear / final-sale rules; promo code released on cancel
- [x] Standalone React + Vite chat app; shared `@tf/chat-ui`

### Phase 4: Azure AI foundation + RAG data 🟡
- [x] 51 knowledge docs (incl. refund, delivery, cancellation, damaged/lost, policies overview) + 114 generated product docs
- [x] `rag:prepare` and `rag:ingest` scripts (heading-aware chunking, two indexes, vector + semantic config)
- [x] Provisioned Azure OpenAI (`gpt-5-mini`, `text-embedding-3-small`) + Azure AI Search (Free) in Southeast Asia; `.env` filled (guides: [Azure OpenAI Setup](azure-openai-setup.md), [Azure AI Search for RAG](azure-ai-search-rag-setup.md))
- [x] Portal walkthrough (wizard index for knowledge) + `rag:ingest`: `tf-products` 574 chunks, `tf-knowledge` 380 chunks
- [ ] RAG eval set: ~30 questions with expected source docs; report hit@3

### Phase 5: Assistant core 🟡
- [x] Assistant service: one agent, private function tools + MCP tools, Postgres session, SSE protocol, gateway proxy
- [x] Chat widget in the store + full-screen chat app
- [x] **Separate-app boundary:** assistant has no store API calls; function tools removed; store reached only via MCP through the gateway
- [x] `mcp-account` server (per-user, user JWT per request) + gateway `/mcp/*` publishing (with `x-mcp-key`); admin approvals composed by the gateway
- [x] MCP tool filter: agent sees only live catalog tools (`get_product`, `check_stock`, `get_reviews`)
- [x] RAG tools built: `search_catalog` (tf-products, filters + category facets, dedupe per product) and `search_knowledge` (tf-knowledge, citations); hybrid + semantic with fallback
- [x] RAG tools verified live on Azure: list/count products (114, 12 per category), filtered product search, policy answers with citations, combined with account MCP
- [x] MCP servers `mcp-catalog` (5 tools, resource + template, prompt) and `mcp-promotions` (3 tools, resource, prompt) on a shared `@tf/mcp-kit` host (Streamable HTTP, stateless)
- [x] Assistant connects with `connectMcpServers` (`dropFailed`, 30 s retry); falls back to local function tools when a server is down; `/api/admin/assistant/status`
- [x] `npm run smoke:mcp` (19 checks) and `npm run mcp:inspector`
- [x] Model provider switch: `MODEL_PROVIDER=azure|openai|auto` (+ `EMBEDDING_PROVIDER`); OpenAI key works today, Azure when provisioned
- [x] Verified end to end with a live model (OpenAI `gpt-5-mini`): MCP `search_products` chosen with filters, token-by-token streaming

### Phase 6: Login-aware chat & memory 🟡
- [x] `AUTH_REQUIRED` tool result → `auth_required` SSE event → Log in button in the chat
- [x] Guest conversation adopted on login; other users get a fresh conversation
- [x] Dynamic instructions per user; history endpoint for the UI
- [x] Live-model test of pre-login → `auth_required` → login → same conversation continues with private tools (OpenAI provider)
- [ ] Session trimming (keep the last N turns) to control token cost

### Phase 7: Multi-agent ⬜
- [ ] Concierge triage agent with `handoff()` to Product Expert, Order Support, Deals (inputFilter, onHandoff, typed inputType)
- [ ] Product Expert exposed to Deals via `asTool()`
- [ ] Structured output (zod `outputType`) for classifiers and recommendations
- [ ] `agent` / handoff SSE events shown in the chat UI
- [ ] Admin-only tools gated with `isEnabled`

### Phase 8: Guardrails & safety ⬜
- [ ] **8a. Deterministic (no Azure needed):** secrets/PII input regex; order-number + rate-limit tool guardrails; citation and invented-number/promo-code output checks; `guardrail` SSE event + chat UI notice
- [ ] **8b. Model-based:** small-model input classifier (off-topic, jailbreak, other-customer data) with `runInParallel: false`; optional grounding judge; Azure content filters / Prompt Shields
- [ ] **8c. RAG:** relevance cutoff → "I don't know"; injection scan on retrieved chunks (tool output guardrail); retrieved ids tracked in RunContext; low-trust content kept out of the index
- [ ] **8d. Red-team eval:** ~30 attack prompts with expected outcomes (`scripts/evals/guardrails.ts`), run in CI
- [ ] Guardrail trips logged to `traces`; doc `research/guardrails.md`

### Phase 9: Agentic workflows + human-in-the-loop ⬜
- [ ] Refund workflow: `/returns/check` → reason classifier → auto ≤ $100 → `needsApproval` above → `RunState` saved in `pending_runs` → admin approves → resume → refund
- [ ] Assistant tools: cancel order, start return (with tool guardrails from Phase 8)
- [ ] Promo matching workflow (parallel fetch → rank → explain)
- [ ] Campaign drafter (admin) with output guardrail + approval → send
- [ ] Restock proposals from low stock → approval → restock
- [ ] Optional: automatic order-stage simulator (preparing → on the way → delivered on a timer)

### Phase 10: Observability & evals ⬜
- [ ] Custom tracing processor → Postgres `traces`/`spans`; `withTrace` + custom spans around workflows
- [ ] Admin trace viewer (runs, tool calls, guardrail trips, token usage)
- [ ] Lifecycle hooks: audit log of money-moving actions
- [ ] Quality evals: RAG hit rate, answer groundedness, workflow success rate; dashboards in Application Insights (prod)

### Phase 11: Deployment ⬜ (details in [Deployment Plan](deployment-plan.md))
- [ ] Production config changes (gateway CORS allow-list, BFF shared secret, chat app API base URL, runtime `GATEWAY_URL`)
- [ ] Azure infrastructure as code (Bicep): Postgres Flexible Server, Container Apps env, ACR, Key Vault, Managed Identity, OpenAI, AI Search, Static Web Apps, monitoring
- [ ] Container images for 9 services; migration job; RAG ingest job
- [ ] Next.js storefront on Vercel (monorepo root `apps/web`), env vars, preview → staging
- [ ] React chat app on Azure Static Web Apps
- [ ] GitHub Actions CI/CD; custom domains; go-live checklist

### Phase 12: Stretch ⬜
- [ ] Realtime voice agent ("talk to support")
- [ ] Recommendation agent from order history; review summarisation (low-trust content handled safely)
- [ ] Multi-instance hardening: Redis for sessions/rate limits, autoscaling tests
