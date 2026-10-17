# TrailForge: Deployment Plan

> **Target:** the **Next.js storefront on Vercel** (a third-party host) and **everything else on Azure**: microservices, gateway, assistant, MCP servers, PostgreSQL, Azure OpenAI, Azure AI Search and the standalone chat app.
> This is Phase 11 of the [Implementation Plan](implementation-plan.md). Status: ⬜ not started · Last updated: 2026-10-17

## 1. Target architecture

```
                    Browser
          ┌────────────┴─────────────┐
          ▼                          ▼
  ┌──────────────────┐      ┌───────────────────────────┐
  │ VERCEL            │      │ AZURE STATIC WEB APPS      │
  │ apps/web (Next.js)│      │ apps/chat (React + Vite)   │
  │ www.trailforge…   │      │ chat.trailforge…           │
  │ Server Components │      │ static SPA, token in       │
  │ + BFF route       │      │ localStorage               │
  │ handler (cookie)  │      └─────────────┬─────────────┘
  └────────┬─────────┘                    │ HTTPS + CORS
           │ HTTPS (server → server)       │
           ▼                               ▼
  ┌──────────────────────── AZURE: resource group rg-trailforge-prod ─────────────────────────┐
  │  Azure Container Apps environment (VNet, Log Analytics)                                  │
  │   ┌──────────────┐  external ingress: api.trailforge…                                    │
  │   │   gateway    │──────────────┐                                                        │
  │   └──────────────┘              │ internal ingress only (http://<app-name>)              │
  │     customer · catalog · inventory · order · payment · promotion · marketing             │
  │     mcp-catalog · mcp-promotions · mcp-account (published by the gateway at /mcp/*)    │
  │     assistant ──► gateway /mcp/* only (+ its own Azure AI Search indexes)              │
  │     jobs: db-migrate · db-seed (demo) · rag-ingest                                       │
  │                                                                                         │
  │   Azure Database for PostgreSQL Flexible Server (8 databases: tf_customer … tf_assistant)│
  │   Azure OpenAI (gpt-5-mini, text-embedding-3-small)   Azure AI Search (tf-products, tf-knowledge)│
  │   Azure Container Registry · Key Vault · Managed Identity · Application Insights         │
  └─────────────────────────────────────────────────────────────────────────────────────────┘
```

**What runs where**

| Component | Where | Why |
|---|---|---|
| `apps/web` (Next.js 16) | **Vercel** | First-class Next.js host: Server Components, streaming route handlers, previews per PR, instant rollback |
| `apps/chat` (Vite SPA) | Azure Static Web Apps (Free) | Static files on a global CDN; no server needed |
| gateway | Azure Container Apps, **external** ingress | The only public API entry point |
| 7 domain services + assistant + MCP servers | Azure Container Apps, **internal** ingress | Not reachable from the internet; called by the gateway / assistant by app name |
| PostgreSQL | Azure Database for PostgreSQL Flexible Server | Managed backups, patching, one server with 8 databases (database per service) |
| Azure OpenAI, AI Search | Azure | Already the AI stack; reached with Managed Identity (no keys) |
| Secrets | Azure Key Vault (+ Vercel encrypted env vars) | `JWT_SECRET`, `INTERNAL_TOKEN`, DB password never in code |

## 2. Environments

| Environment | Web | Backend | Data |
|---|---|---|---|
| **local** | `next dev` :5173 | `npm run dev` + Docker Postgres | `npm run db:reset` seed |
| **production** | Vercel production (`main` branch) | `rg-trailforge-prod` | Seeded once for the demo, then real usage |
| **preview** | Vercel preview per pull request | Same Azure backend (read mostly) | Previews protected by Vercel Deployment Protection |
| *(later)* staging | Vercel preview env vars → staging gateway | `rg-trailforge-staging` | Its own seeded database |

For a learning project, one Azure environment is enough. Add staging once previews start writing test orders you don't want in production.

## 3. Code changes needed before deploying

| # | Change | Where | Why |
|---|---|---|---|
| 1 | **Dockerfile** (multi-stage, `SERVICE` build arg, Node 24 alpine, non-root user, `PORT=8080`) + `.dockerignore` | repo root | Package every Express service as a container |
| 2 | **Postgres SSL**: `ssl: { rejectUnauthorized: true }` when `PGSSLMODE=require` | `packages/shared/src/db.ts` | Azure Flexible Server requires TLS |
| 3 | **Gateway CORS allow-list** from `ALLOWED_ORIGINS` (today it only allows `localhost:517x`) | `services/gateway/src/index.ts` | Let the chat app on Static Web Apps call the API |
| 4 | **Chat app API base**: `VITE_API_BASE` (default `/api`) passed to `useChat` | `apps/chat/src` | In production there is no Vite proxy |
| 5 | **Runtime `GATEWAY_URL`**: remove it from the `env` block in `next.config.ts` (which bakes values in at build time); read `process.env` on the server | `apps/web/next.config.ts`, `lib/session.ts` | Change the backend URL without rebuilding |
| 6 | **Rate limiting** on `/api/auth/*` and `/api/chat` (per IP + per user) | gateway | The gateway is public; protects login and model spend |
| 7 | **Health & readiness**: `/healthz` exists; add a DB ping to `/readyz` | `createService` | Container Apps probes |
| 8 | **Production safety switches**: `NODE_ENV=production` in images (turns off dev quick-login); refuse to start if `JWT_SECRET` is the dev default | shared config | Never ship impersonation or dev secrets |
| 9 | Service URLs from env (already done) → `http://customer`, `http://catalog`, … | Container App env vars | Internal DNS inside the environment |
| 10 | **Migrations runner image** (`npm run db:migrate`) and an optional seed job | `scripts/db` | Schema changes run before new code goes live |

## 4. Azure resources

All created with **Bicep** in `infra/azure/` (`main.bicep` + modules) so the environment can be rebuilt with one command.

| Resource | SKU / setting (learning-friendly) | Notes |
|---|---|---|
| Resource group | `rg-trailforge-prod`, region **East US 2** | Pick a region where `gpt-5-mini` + `text-embedding-3-small` are available (`az cognitiveservices model list -l <region>`) |
| Log Analytics + Application Insights | Pay-as-you-go, 30-day retention | Container logs, traces (Phase 10) |
| Container Registry | Basic, admin user **off** | Images pulled with Managed Identity (AcrPull) |
| User-assigned Managed Identity | `id-trailforge-apps` | Used by all Container Apps and jobs |
| Key Vault | Standard, RBAC mode | `jwt-secret`, `internal-token`, `pg-password`; apps read via Key Vault references |
| PostgreSQL Flexible Server | **Burstable B1ms**, PG 17, 32 GB, 7-day backups, TLS required | 8 databases created by the migrate job; app user with least privilege per database (later) |
| Container Apps environment | Consumption plan, VNet-integrated | Internal ingress for everything except the gateway |
| Container Apps | gateway, customer, catalog, inventory, order, payment, promotion, marketing, assistant (+ MCP servers) | 0.5 vCPU / 1 GiB each to start |
| Container Apps jobs | `db-migrate` (manual/CI), `db-seed` (manual, demo only), `rag-ingest` (manual) | Same image, different command |
| Azure OpenAI | S0 + deployments `gpt-5-mini`, `text-embedding-3-small` (GlobalStandard) | Role **Cognitive Services OpenAI User** for the identity |
| Azure AI Search | **Basic** (semantic ranker) or **Free** (no semantic ranker, 1 per subscription) | Roles **Search Index Data Reader** (assistant), **Contributor** (ingest job) |
| Static Web Apps | Free | Hosts `apps/chat` |

**Networking choice**

| Option | Setup | Use when |
|---|---|---|
| A. Public Postgres + firewall ("Allow Azure services") | Simplest | First deployment / learning |
| B. **VNet**: Container Apps env in a VNet, Postgres with private access (delegated subnet) | More Bicep, no public DB endpoint | Recommended once it works; required for real data |

Start with A, then move to B as a learning step. The app code doesn't change, only `PGHOST`.

**Scaling**

| App | Min / max replicas | Reason |
|---|---|---|
| gateway | 1 / 5 | No cold start on the public entry point |
| assistant | 1 / 3 | Chat latency; sessions are in Postgres, so it scales horizontally |
| domain services | 0–1 / 3 | Scale to zero saves money; set min 1 on order + catalog if cold starts hurt checkout |
| MCP servers | 0 / 2 | Stateless (Streamable HTTP) |

**Container App environment variables** (per app)

| Variable | Value | Source |
|---|---|---|
| `NODE_ENV` | `production` | plain |
| `PORT` | `8080` | plain |
| `PGHOST`, `PGUSER`, `PGPORT`, `PGSSLMODE=require` | Flexible Server values | plain |
| `PGPASSWORD` | | Key Vault `pg-password` |
| `JWT_SECRET`, `INTERNAL_TOKEN` | | Key Vault |
| `CUSTOMER_URL` … `ASSISTANT_URL` | `http://customer`, `http://catalog`, … | plain (internal DNS) |
| `MCP_CATALOG_URL`, `MCP_PROMOTIONS_URL`, `MCP_ACCOUNT_URL` | `http://mcp-catalog/mcp`, `http://mcp-promotions/mcp`, `http://mcp-account/mcp` | plain (gateway → internal MCP servers) |
| `STORE_MCP_BASE_URL` | `https://api.trailforge…/mcp` (the PUBLIC gateway) | plain (assistant: it reaches the store only through here) |
| `MCP_HOST` | `0.0.0.0` | MCP servers (bind for container networking) |
| `MCP_AUTH_TOKEN` | | Key Vault (gateway adds it as `x-mcp-key`; MCP servers require it) |
| `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_CHAT_DEPLOYMENT`, `AZURE_OPENAI_EMBEDDING_DEPLOYMENT` | | plain (assistant, ingest job) |
| `AZURE_SEARCH_ENDPOINT`, `AZURE_SEARCH_*_INDEX` | | plain (assistant, ingest job) |
| `AZURE_CLIENT_ID` | Managed Identity client id | plain (so `DefaultAzureCredential` picks the right identity) |
| `ALLOWED_ORIGINS` | `https://www.trailforge…,https://chat.trailforge…` + Vercel preview pattern | gateway only |
| `DEV_QUICK_LOGIN` | `false` | belt and braces |

## 5. Vercel (Next.js storefront)

| Setting | Value |
|---|---|
| Project | Import GitHub `mk-tdev/trailforge` |
| **Root Directory** | `apps/web` (keep "Include files outside the Root Directory" on: `@tf/chat-ui` lives in `packages/`) |
| Framework preset | Next.js (auto-detected); install runs from the repo-root `package-lock.json` (npm workspaces) |
| Node.js | 24.x (Vercel default) |
| Build command | `next build` (default) |
| Production branch | `main` → production; every PR → preview URL |
| Function region | Close to the Azure region (e.g. `iad1` for East US 2), set in `vercel.ts` / project settings, so the BFF ↔ gateway hop is a few ms |
| Fluid compute | On (default). Streaming chat responses work on the Node.js runtime; default max duration 300 s is plenty for SSE chat |

**Environment variables** (Vercel → Settings → Environment Variables, or `vercel env add`)

| Variable | Production | Preview | Notes |
|---|---|---|---|
| `GATEWAY_URL` | `https://api.trailforge…` | same (or staging gateway) | Server-only; never `NEXT_PUBLIC_` |
| `NEXT_PUBLIC_CHAT_APP_URL` | `https://chat.trailforge…` | same | Link to the full-screen chat |

The browser never talks to Azure directly from the storefront. It calls the Next.js BFF (`/api/[...path]`), which adds the httpOnly-cookie token and calls the gateway server-to-server. The session cookie lives on the Vercel domain (`secure`, `httpOnly`, `sameSite=lax`).

**Vercel ↔ Azure security notes**
- Vercel functions don't have fixed outbound IPs on standard plans, so the gateway can't be locked to Vercel's IPs. Protection comes from JWT auth, the CORS allow-list, rate limiting and internal-only services. Add Azure Front Door + WAF later if needed.
- Preview deployments are protected by Vercel Deployment Protection (login required), so nobody else reaches the shared backend through them.

## 6. Chat app on Azure Static Web Apps

- Build: `npm ci && npm run build -w @tf/chat` → output `apps/chat/dist`, with `VITE_API_BASE=https://api.trailforge…/api` and `VITE_STORE_URL=https://www.trailforge…`.
- Deploy with the Static Web Apps GitHub Action (`app_location: apps/chat`, `output_location: dist`, `skip_app_build` after our own build step).
- SPA fallback route (`staticwebapp.config.json`: `navigationFallback` → `/index.html`).
- It calls the gateway directly (CORS), keeping the token in localStorage. This is the deliberate contrast with the storefront's cookie BFF.

## 7. Data: migrations, seed, RAG

| Task | How | When |
|---|---|---|
| Create databases + run migrations | `db-migrate` Container Apps job (`npm run db:migrate`, which creates databases if missing) | Every deploy, **before** new revisions |
| Seed demo data | `db-seed` job (`npm run db:reset`, which is **destructive**) | Once for the demo; never on real data |
| Index RAG docs | `rag-ingest` job (`npm run rag:prepare && npm run rag:ingest`) | After docs change |
| Backups | Flexible Server automatic backups (7 days); point-in-time restore | Always on |

Migrations must be **backwards-compatible** (add columns/tables first, remove later), because the old revision keeps serving traffic while the new one starts.

## 8. CI/CD (GitHub Actions)

```
pull request ─► ci.yml: typecheck · build web/chat · API smoke test (Postgres service container)
             └► Vercel: preview deployment (Git integration)

push to main ─► ci.yml (same checks)
             ├► deploy-azure.yml:
             │     1. azure/login (OIDC federated credential, no secrets stored)
             │     2. az acr build per changed service  (tag = git SHA)
             │     3. start db-migrate job, wait for success
             │     4. az containerapp update --image …:<sha>   (new revision; old one kept)
             │     5. smoke test against https://api.trailforge…/healthz
             ├► deploy-chat.yml: build apps/chat → Static Web Apps
             └► Vercel: production deployment of apps/web (Git integration)
```

- **Azure auth:** a GitHub OIDC federated credential on an Entra app registration with `AcrPush` + `Contributor` on the resource group. No long-lived secrets in GitHub.
- **Rollback:** Container Apps keeps old revisions (`az containerapp revision activate`); Vercel has instant rollback to any previous deployment.

## 9. Domains & TLS

| Host | Points to | Certificate |
|---|---|---|
| `www.trailforge…` (+ apex redirect) | Vercel | Vercel-managed |
| `api.trailforge…` | gateway Container App | Container Apps managed certificate |
| `chat.trailforge…` | Static Web Apps | SWA-managed |

Until a domain is bought, use the default `*.vercel.app`, `*.azurecontainerapps.io` and `*.azurestaticapps.net` URLs, and put them in `ALLOWED_ORIGINS` / `GATEWAY_URL`.

## 10. Observability

- **Azure:** Container Apps console logs → Log Analytics; OpenTelemetry → Application Insights (Phase 10) with request traces across gateway → services; alerts on 5xx rate, p95 latency, Postgres CPU/storage, OpenAI 429s.
- **Agent traces:** the custom Agents SDK trace processor writes runs, tool calls and guardrail trips to `tf_assistant` (viewable in the admin console).
- **Vercel:** function logs and Observability for the storefront; Web Analytics / Speed Insights optional.

## 11. Cost estimate (monthly, learning scale)

| Item | Approx. |
|---|---|
| PostgreSQL Flexible Server B1ms + 32 GB | ~$15–25 |
| Container Apps (consumption; 2 apps with min 1 replica, rest scale to zero) | ~$10–40 |
| Container Registry Basic | ~$5 |
| Azure AI Search **Basic** (or Free: $0, no semantic ranker) | ~$75 (or $0) |
| Azure OpenAI tokens (light use) | ~$1–10 |
| Log Analytics / App Insights | ~$2–10 |
| Static Web Apps Free, Key Vault | ~$0–1 |
| Vercel Hobby (personal, non-commercial) / Pro | $0 / $20 |
| **Total** | **≈ $35–60 with Free search, ≈ $110–135 with Basic search** |

These are rough estimates; check the Azure pricing calculator and Vercel pricing. Delete the resource group when you're done practising (`az group delete -n rg-trailforge-prod`).

## 12. Rollout steps

1. [ ] Make the code changes in §3; verify locally with `docker build` + `docker run` for one service
2. [ ] Write Bicep (`infra/azure/main.bicep`); `az deployment group what-if`, then deploy
3. [ ] Store secrets in Key Vault; grant the Managed Identity its roles (AcrPull, Key Vault Secrets User, OpenAI User, Search Index Data Reader)
4. [ ] Build and push images (`az acr build`); run `db-migrate`, then `db-seed` once
5. [ ] Deploy Container Apps; check `/healthz` on the gateway; check internal calls in the logs
6. [ ] Run `rag-ingest`; test a search query
7. [ ] Create the Vercel project (root `apps/web`), set env vars, deploy; log in as the demo user
8. [ ] Build and deploy the chat app to Static Web Apps; add its origin to `ALLOWED_ORIGINS`
9. [ ] Set up GitHub Actions (OIDC) + Vercel Git integration
10. [ ] Custom domains + TLS
11. [ ] Go-live checklist (§13)

## 13. Go-live checklist

- [ ] `DEV_QUICK_LOGIN` off: `GET https://api…/api/dev/accounts` returns **404**
- [ ] `JWT_SECRET` and `INTERNAL_TOKEN` are strong random values from Key Vault (not the dev defaults)
- [ ] Only the gateway has external ingress; `customer`, `order`, … are unreachable from the internet
- [ ] `/internal/*` routes are never exposed by the gateway (they need `x-internal-token`)
- [ ] CORS allows only the storefront and chat origins
- [ ] Rate limits on login and chat
- [ ] Postgres: TLS required, backups on, not open to `0.0.0.0/0`
- [ ] Azure OpenAI / Search reached with Managed Identity (no keys in env)
- [ ] Session cookie `secure` + `httpOnly` on the Vercel domain
- [ ] Guardrails (Phase 8) enabled; refunds over $100 still require admin approval
- [ ] Smoke test + red-team eval pass against production
- [ ] Budget alert on the resource group
