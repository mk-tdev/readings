# TrailForge: Application Context

> Paste or reference this file at the start of a new chat so the assistant knows what we're building, why, how it's structured, where it stands, and the rules to follow.
> Repo: https://github.com/mk-tdev/trailforge (private) · Local: `~/workspace/learning/trailforge`
> Companion course repo: https://github.com/mk-tdev/agentic-ai (fundamentals: Agents SDK, Azure OpenAI, AI Search, MCP, RAG)

---

## 1. What we are building

**TrailForge** is a fictional **outdoor & hiking gear e-commerce store** built as a realistic full-stack system:

- A **Next.js storefront + admin console** where customers browse, search, buy, track orders, request returns and see promotions.
- **Independent Node.js + Express microservices**, each owning its own **PostgreSQL** database: customer, catalog, inventory, order, payment, promotion, marketing. A gateway (BFF) sits in front of them.
- An **agentic AI assistant** (its own service) built *only* with the **OpenAI Agents SDK for JavaScript**, running on **Azure OpenAI**, using **Azure AI Search** for agentic RAG. It is a **standalone chat package** that is:
  - embedded as a **chat widget** inside the Next.js store, and
  - served as a **full-screen chat app** (React + Vite).

The assistant must:
- Answer questions about **products, policies, and public promotions** for anonymous visitors.
- **Know whether the user is logged in.** For private questions (orders, account, personal offers, refunds) it prompts the user to log in, then continues the same conversation afterwards.
- Show **personal promotions** based on the logged-in customer: tier, birthday, segments, first order.
- Run **agentic workflows**:
  - automated refunds, with human approval above $100;
  - promo matching;
  - marketing campaign drafting;
  - restock proposals.

  Each workflow talks to the other microservices.

## 2. Why we are building it

This is a **learning project**. The goal is to learn agentic AI the *realistic* way: inside a messy, multi-service business system with real data, auth, policies and edge cases, not in a toy demo.

- **No agent orchestration frameworks** (no LangGraph, LangChain, CrewAI, etc.). Every concept is implemented "raw" with the **OpenAI Agents SDK** (https://openai.github.io/openai-agents-js/) and plain TypeScript, so the mechanics are visible.
- Every Agents SDK concept should be used somewhere real (see §5).
- Repeatable data: the whole world can be scrubbed and recreated anytime (`npm run db:reset`).
- Everything is documented as we go (`research/`) so the user can study it.

The user is a developer **learning these topics as a beginner**. They know they need Node/TypeScript refreshers. Explanations should be clear and in plain language, and code should be readable with useful comments.

## 3. Learning objectives

By the end, the user should be able to explain and build:

1. **Microservices fundamentals:** database-per-service, service-to-service HTTP calls, an API gateway/BFF, sagas with compensating actions (checkout), idempotency (refunds), and data snapshots (order items).
2. **Auth across services:** JWT issued by the customer service and verified by every service; trusted internal calls (`x-internal-token`); httpOnly-cookie BFF (Next.js) vs localStorage token (Vite SPA).
3. **OpenAI Agents SDK, end to end:** agents, tools, MCP, handoffs, guardrails, sessions, streaming, structured output, human-in-the-loop, tracing (full map in §5).
4. **Agentic RAG with Azure AI Search:**
   - data preparation and chunking;
   - two indexes (products, knowledge);
   - hybrid search (BM25 + vectors + RRF);
   - semantic ranker and filters;
   - citations;
   - an eval set.
5. **Static vs live data:** facts that change (stock, prices, order status, promos) come from APIs at answer time; static knowledge comes from the search index.
6. **Security in agent systems:**
   - identity comes from RunContext, never from LLM arguments;
   - prompt-injection awareness;
   - least-privilege tools;
   - approval gates for money-moving actions.
7. **MCP servers:** exposing public catalog and promotions over Streamable HTTP.
8. **Azure:** Azure OpenAI (deployments, Entra ID auth), Azure AI Search, and later Azure Container Apps + Azure Database for PostgreSQL.

## 4. Technology stack

| Layer | Technology |
|---|---|
| Language/runtime | **TypeScript**, **Node.js 24**, npm workspaces monorepo |
| Backend services | **Express 5**, zod validation, `pg` with **plain SQL** + SQL migration files (no ORM), `jose` JWT, Node `scrypt` password hashing |
| Database | **PostgreSQL 17** in Docker (one container, one database per service) + pgAdmin |
| Web app | **Next.js 16 (App Router)**: Server Components, Route Handlers, a `proxy.ts` route guard, auth in an httpOnly cookie |
| Chat app | **React 19 + Vite** SPA |
| Shared chat UI | `packages/chat-ui`: React components (`ChatWidget`, `ChatPage`, `useChat`), manual SSE parsing |
| AI | **OpenAI Agents SDK (`@openai/agents` 0.20)**, `openai` SDK, **Azure OpenAI** (`gpt-5-mini`, `text-embedding-3-small`) through the v1 endpoint, Entra ID via `@azure/identity`; or **OpenAI platform** with `MODEL_PROVIDER=openai` (auto-detected when only `OPENAI_API_KEY` is set) |
| Retrieval | **Azure AI Search** (`@azure/search-documents`): indexes `tf-products`, `tf-knowledge` |
| Tools protocol | **MCP** (`@modelcontextprotocol/sdk`, Streamable HTTP) |
| Seed data | `@faker-js/faker` with a fixed seed (deterministic) |

## 5. OpenAI Agents SDK concept map (target)

| Concept | Where it is or will be used |
|---|---|
| Agent, instructions, modelSettings, `run`, agent loop, `maxTurns` | All agents |
| **Dynamic instructions** | Before/after login personalisation ✅ |
| **Function tools** (zod), `isEnabled`, tool errors | Public + private tools ✅ |
| **RunContext** (local context, never sent to the LLM) | Customer identity + JWT ✅ |
| **Custom Session** (Postgres) | Conversation memory ✅ |
| **Streaming events → SSE** | Chat ✅ |
| MCP servers (Streamable HTTP), tool filtering | Catalog / promotion MCP |
| Agents as tools (`asTool`) | Product Expert used by Deals |
| **Handoffs** (`handoff()`, inputFilter, onHandoff, inputType) | Concierge → Product Expert / Order Support / Deals |
| Structured output (`outputType`) | Refund decision, ranked offers, campaign draft |
| Input / output / tool guardrails | Off-topic/abuse, PII, invented discounts, refund caps |
| **Human-in-the-loop** (`needsApproval`, interruptions, `RunState` serialize/resume) | Refunds > $100, campaigns, restock |
| Code vs LLM orchestration | Workflows (code) vs handoffs (LLM) |
| Tracing (custom processor, `withTrace`, custom spans) | Traces in Postgres + admin trace viewer |
| Lifecycle hooks / run events | Audit log, token usage |
| Per-agent models | Cheaper model for classifiers/guardrails |
| Realtime voice agents (stretch) | "Talk to support" |

## 6. Architecture (summary)

```
apps/web  (Next.js :5173) ── /api/[...path] BFF (cookie → Bearer) ─┐
apps/chat (Vite    :5174) ── Vite proxy /api (localStorage token) ─┤
                                                                   ▼
                          services/gateway (Express :3000) /api/*
   ┌──────────┬──────────┬───────────┬────────┬─────────┬───────────┬───────────┬───────────┐
customer:4001 catalog:4002 inventory:4003 order:4004 payment:4005 promotion:4006 marketing:4007 assistant:4100
   └─ each owns its own database: tf_customer, tf_catalog, … tf_assistant (Postgres :5432) ─┘
assistant → Azure OpenAI, Azure AI Search, MCP servers, other services (REST, with the user's JWT)
```

Key rules:
- **No cross-database access at runtime.** Services call each other's APIs. Only the seed script writes to all databases.
- **Money is integer cents.** JSON is camelCase; SQL is snake_case.
- **Identity comes from the verified JWT** and lives in the Agents SDK RunContext. Customer ids are never tool parameters.
- **Private tools stay enabled for guests but return `AUTH_REQUIRED`.** The server then emits an `auth_required` SSE event, and the UI shows a Log in button.
- **Order stages after placement:** `preparing → on_the_way → delivered` (admin advances them; history in `order_status_history`). Checkout commits inventory; cancel and return restock it.
- **The return policy** lives in `packages/shared/src/types.ts` (`RETURN_POLICY`):
  - 60 days from delivery; electronics 30 days;
  - climbing gear is non-returnable;
  - refunds ≤ $100 are approved automatically.

Full contracts (ports, every endpoint, SSE events, data shapes) are in **`research/architecture.md`**. How the workspace runs: **`research/monorepo-guide.md`**. MCP servers: **`research/mcp-guide.md`**. Azure setup: **`research/azure-openai-setup.md`**, **`research/azure-ai-search-rag-setup.md`**. The plan and phases are in **`research/implementation-plan.md`**.

## 7. Repository map

```
packages/shared     config, db (pool/one/many/tx), migrate, auth, http (createService), errors,
                    service client, pricing (priceOrder), segments (segmentsFor/tierFor), types
packages/chat-ui    ChatWidget, ChatPanel, ChatPage, useChat, SSE parser, styles (tfc- prefix)
services/<name>     src/index.ts (Express) + migrations/*.sql
services/mcp-*      MCP servers (catalog :4201, promotions :4202) on packages/mcp-kit
services/assistant  src/agent.ts, mcp.ts, context.ts, session.ts (PostgresSession), tools/public.ts, tools/private.ts
apps/web            Next.js: app/, components/, lib/gateway.ts (server-only), proxy.ts, app/api/session, app/api/[...path]
apps/chat           Vite React full-screen chat
data/               products.json (114 products, 527 variants), promotions.json (13 promos)
rag/knowledge/      47 handwritten docs (policies, privacy, about, stores, guides, FAQs)
rag/products/       114 generated product docs (npm run rag:prepare)
scripts/db          reset.ts, migrate.ts, seed.ts      scripts/rag   prepare.ts, ingest.ts
scripts/smoke       api-smoke.mjs (21 end-to-end API checks)
research/           application-context.md (this file), implementation-plan.md, architecture.md, deployment-plan.md, monorepo-guide.md, mcp-guide.md, azure-openai-setup.md, azure-ai-search-rag-setup.md (+ .html)
```

## 8. Commands & test data

```bash
npm run db:up          # Postgres + pgAdmin (Docker)
npm run db:reset       # drop/recreate all DBs + migrate + seed (deterministic)
npm run dev            # all services + assistant + web (5173) + chat (5174)
node scripts/smoke/api-smoke.mjs
npm run rag:prepare && npm run rag:ingest   # needs Azure config in .env
npm run typecheck && npm run build -w @tf/web
```

| Account | Password | Purpose |
|---|---|---|
| `demo@trailforge.example` (Alex Rivera, Gold) | `Password123!` | Edge-case orders: refund > $100 (needs approval), refund ≤ $100 (auto), outside the return window, in transit, cancellable. Birthday this month. |
| `admin@trailforge.example` | `Admin123!` | One admin console (`/admin`): overview, all customers' orders with stage controls, full inventory with restock, customers, approvals |
| 29 other customers (`…@example.com`) | `Password123!` | Personas: heavy, regular, occasional, lapsed, no orders |

Seed: 30 customers + 1 admin, 114 products, 100 orders over 12 months, payments, shipments, returns and refunds, reviews, loyalty tiers and segments computed from the order history, inbox messages, campaigns.

## 9. Current status (as of 2026-10-17)

Full checklist per phase: **`research/implementation-plan.md` §12**. Deployment (Vercel + Azure): **`research/deployment-plan.md`**.

| Phase | State |
|---|---|
| 1. Scaffold | ✅ |
| 2. Microservices + seed | ✅ |
| 3. Next.js storefront, admin console, auth, order stages | ✅ |
| 4. Azure AI foundation + RAG data/ingest/eval | 🟡 docs + scripts done · 🔒 Azure not provisioned |
| 5. Assistant core (search tools, MCP, streaming) | 🟡 MCP + live streaming verified with OpenAI; `search_knowledge` needs Azure AI Search |
| 6. Login-aware chat & memory | ✅ verified live |
| 7. Multi-agent (handoffs, agents as tools, structured output) | ⬜ |
| 8. Guardrails & safety (8a deterministic can start now) | ⬜ |
| 9. Agentic workflows + human-in-the-loop | ⬜ |
| 10. Observability & evals | ⬜ |
| 11. Deployment: Next.js → Vercel, everything else → Azure | ⬜ |
| 12. Stretch (voice etc.) | ⬜ |

**Blockers / next steps:**
1. Provision Azure OpenAI (`gpt-5-mini`, `text-embedding-3-small`) and Azure AI Search, then fill `AZURE_OPENAI_ENDPOINT` and `AZURE_SEARCH_ENDPOINT` in `.env`. Keys are optional: Entra ID via `az login` works.
2. `npm run rag:ingest`, then add a `search_knowledge` tool (hybrid search with citations) to the assistant.
3. Phase 7: Concierge + specialist agents with handoffs; Phase 8a: deterministic guardrails (can start without Azure).

MCP servers (catalog, promotions) are built and connected. See `research/mcp-guide.md`.

**Known gaps:**
- Many knowledge docs are short (avg ~360 words) and could be expanded.
- A missing order page under `/account/orders/...` returns 200 with a not-found page instead of a 404.

## 10. Working agreements for the assistant (next chat)

- Use **only the OpenAI Agents SDK** for agent logic. No LangGraph or similar.
- Keep backend services on **Express 5**, the web app on **Next.js 16**, and the chat app on **React + Vite**.
- Respect **service boundaries**: no cross-database queries; add an endpoint instead.
- Follow the existing helpers in `@tf/shared` (`createService`, `one`/`many`/`tx`, `services.<name>()`, `HttpError`).
- Update `research/architecture.md` when the API or SSE contract changes, then run `npm run research:html`.
- Verify against the installed package types in `node_modules` before using an SDK API. Run the smoke test after backend changes.
- Explain concepts for a beginner and keep code comments educational.
- Commit or push only when asked. GitHub account: `mk-tdev`.
