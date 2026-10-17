# Monorepo Guide: How the TrailForge Workspace Works

> Your reference for how this repository is organised, how its packages find each other, how it runs, and how to manage it day to day.
> Applies to: npm workspaces (npm 11, Node 24), TypeScript project references, Next.js, Vite.

## 1. The big idea in one minute

TrailForge is **one Git repository that holds 19 small Node.js packages** (services, apps, shared libraries, scripts). This setup is called a **monorepo**. Two features make it work:

1. **npm workspaces**: npm treats every folder matched by the `workspaces` patterns as a package. One `npm install` at the root installs everything, and packages can import each other by name (`import { createService } from '@tf/shared'`) **without publishing anything to npm**.
2. **TypeScript project references**: `tsc -b` type-checks and builds the backend packages in the right order (shared first, then the services that use it).

```
trailforge/                       ← the "root" (workspace root). You run commands here.
├── package.json                  ← lists the workspaces + root scripts (npm run dev, db:reset…)
├── package-lock.json             ← ONE lockfile for every package
├── node_modules/                 ← ONE dependency folder for every package
│   ├── express/, pg/, next/ …    ← third-party packages, installed once ("hoisted")
│   └── @tf/                      ← symlinks to our own packages
│       ├── shared  → ../../packages/shared
│       ├── order   → ../../services/order
│       └── …
├── packages/*   services/*   apps/*   scripts/*      ← the workspace packages
```

## 2. What the `workspaces` patterns match

```json
"workspaces": ["packages/*", "services/*", "apps/*", "scripts/*"]
```

Each pattern means "every direct sub-folder that has a `package.json` is a package". Today that's 19:

| Folder | Package name | What it is | Runs with |
|---|---|---|---|
| `packages/shared` | `@tf/shared` | Backend library: config, db, migrations, auth, HTTP helpers, service client, pricing, policy constants | imported by others; never runs alone |
| `packages/chat-ui` | `@tf/chat-ui` | React chat components (`ChatWidget`, `ChatPage`, `useChat`) | imported by both front-ends |
| `packages/mcp-kit` | `@tf/mcp-kit` | Shared MCP host (Streamable HTTP) + result helpers | imported by the MCP servers |
| `services/gateway` | `@tf/gateway` | Express BFF, port 3000 | `tsx watch` |
| `services/customer` | `@tf/customer` | Express, 4001, db `tf_customer` | `tsx watch` |
| `services/catalog` | `@tf/catalog` | Express, 4002 | `tsx watch` |
| `services/inventory` | `@tf/inventory` | Express, 4003 | `tsx watch` |
| `services/order` | `@tf/order` | Express, 4004 | `tsx watch` |
| `services/payment` | `@tf/payment` | Express, 4005 | `tsx watch` |
| `services/promotion` | `@tf/promotion` | Express, 4006 | `tsx watch` |
| `services/marketing` | `@tf/marketing` | Express, 4007 | `tsx watch` |
| `services/assistant` | `@tf/assistant` | Express + OpenAI Agents SDK, 4100 | `tsx watch` |
| `services/mcp-catalog` | `@tf/mcp-catalog` | MCP server over the catalog API, 4201 | `tsx watch` |
| `services/mcp-promotions` | `@tf/mcp-promotions` | MCP server over the promotion API, 4202 | `tsx watch` |
| `services/mcp-account` | `@tf/mcp-account` | Per-user MCP server (orders, offers, profile), 4203 | `tsx watch` |
| `apps/web` | `@tf/web` | Next.js 16 storefront + admin, 5173 | `next dev` |
| `apps/chat` | `@tf/chat` | React + Vite full-screen chat, 5174 | `vite` |
| `scripts/db` | `@tf/db-scripts` | reset / migrate / seed | `tsx` (one-off) |
| `scripts/rag` | `@tf/rag-scripts` | RAG prepare / ingest | `tsx` (one-off) |

The **package name** (from each folder's `package.json`, e.g. `"name": "@tf/order"`) is what you use with `-w`. It doesn't have to match the folder name: `scripts/db` is `@tf/db-scripts`. `@tf` is just a **scope** that groups our packages and avoids clashing with real npm packages.

Folders that are **not** workspaces: `data/`, `rag/`, `research/`, `infra/`, `scripts/smoke/` (no `package.json`; it's a plain `.mjs` you run with `node`).

## 3. What `npm install` does here

Run it **once, at the root**:

1. Reads every workspace's `package.json` and works out one dependency tree.
2. **Hoists** shared third-party packages to the root `node_modules/`. `express` is listed in 10 packages but installed once. If two packages needed incompatible versions, npm would put the odd one in that package's own `node_modules/`.
3. **Symlinks** each workspace into `node_modules/@tf/<name>`. That's why `import … from '@tf/shared'` works: Node looks in `node_modules`, finds the symlink, and follows it to `packages/shared`.
4. Writes **one** `package-lock.json` at the root. Commit it; it pins exact versions for everyone (and for Vercel/Azure builds).

You can see the symlinks yourself:
```bash
ls -la node_modules/@tf/
# shared -> ../../packages/shared
# order  -> ../../services/order …
```

**`"@tf/shared": "*"`**: in a service's `dependencies`, `*` means "any version". Because a workspace with that name exists, npm links the local folder instead of downloading from the registry.

## 4. How our packages import each other

### Backend: `@tf/shared` → services and scripts

`packages/shared/package.json` uses **conditional exports**:
```json
"exports": {
  ".": {
    "development": "./src/index.ts",   ← used in dev (tsx --conditions=development)
    "types": "./dist/index.d.ts",      ← used by TypeScript when building
    "default": "./dist/index.js"       ← used in production (plain node)
  }
}
```

| Situation | Command | `@tf/shared` resolves to | Needs a build first? |
|---|---|---|---|
| Local dev | `tsx watch --conditions=development … src/index.ts` | `packages/shared/src/index.ts` (TypeScript source) | **No.** Edit shared, and the service picks it up. |
| Scripts | `tsx --conditions=development src/seed.ts` | source | No |
| Production | `node dist/index.js` | `packages/shared/dist/index.js` (compiled) | **Yes:** `npm run typecheck` (`tsc -b`) first |

`tsx` is a TypeScript runner: it compiles `.ts` on the fly, so in dev nothing needs building. `tsx watch` restarts the service when a file it imports changes, including files in `packages/shared/src`.

### Front-end: `@tf/chat-ui` → `@tf/web` and `@tf/chat`

`@tf/chat-ui` ships **TypeScript source only** (`"exports": { ".": "./src/index.ts" }`), with no build step. The apps compile it themselves:
- **Next.js:** `transpilePackages: ['@tf/chat-ui']` in `apps/web/next.config.ts` tells Next to compile code from that package.
- **Vite:** compiles linked TypeScript packages out of the box.

React is a **peer dependency** of chat-ui (`peerDependencies`): chat-ui uses whatever React the app has installed, so there's only one React instance (two copies break hooks).

```
            @tf/shared ◄──────────── services/* , scripts/*
          (backend lib)                (import '@tf/shared')

            @tf/chat-ui ◄──────────── apps/web (Next.js) , apps/chat (Vite)
          (React components)            (import '@tf/chat-ui')
```

Rule: **backend packages never import front-end packages and vice versa.** `@tf/shared` uses `pg`/`express`, which can't run in a browser.

## 5. TypeScript setup

| File | Purpose |
|---|---|
| `tsconfig.base.json` | Shared compiler settings for **backend** packages (strict, `NodeNext` modules, `composite: true`) |
| `tsconfig.json` (root) | No code of its own; just a list of **references** to every backend package |
| `<package>/tsconfig.json` | `extends` the base, sets `rootDir: src` / `outDir: dist`, and **references** packages it depends on (services reference `../../packages/shared`) |
| `apps/web/tsconfig.json`, `apps/chat/tsconfig.json`, `packages/chat-ui/tsconfig.json` | Front-end settings (`moduleResolution: bundler`, JSX, `noEmit`); the bundler builds them, so they're **not** in the root references |

`npm run typecheck` runs **`tsc -b`** ("build mode"):
- reads the root references, builds `packages/shared` **first**, then each service, in dependency order;
- writes `dist/` folders (git-ignored) plus `*.tsbuildinfo` files so the next run only rebuilds what changed.

Front-ends are checked separately:
```bash
npm run typecheck -w @tf/web
npm run typecheck -w @tf/chat
npm run typecheck -w @tf/chat-ui
```

## 6. Configuration (.env)

- **One `.env` file at the root** for all backend services and scripts. Each `dev`/`start` script passes it with Node's built-in flag: `--env-file-if-exists=../../.env` (the path is relative to the package folder, where npm runs the script).
- `.env.example` is the committed template; `.env` is git-ignored.
- Settings are validated once in `packages/shared/src/config.ts` (zod) with sensible local defaults, so most things work even with an empty `.env`.
- **Next.js does not read the root `.env`.** It reads `apps/web/.env*` files. Today it relies on defaults (`GATEWAY_URL=http://localhost:3000`). On Vercel you set its variables in the project settings.
- **Vite** reads `apps/chat/.env*` and only exposes variables prefixed `VITE_`.

## 7. How the project runs

### The root scripts (run from the repo root)

| Command | What it does |
|---|---|
| `npm install` | Install everything (see §3) |
| `npm run db:up` / `db:down` | Start / stop Postgres + pgAdmin in Docker |
| `npm run db:reset` | Drop + recreate all 8 databases, migrate, seed (destructive) |
| `npm run db:migrate` | Apply pending SQL migrations only (safe) |
| `npm run db:seed` | Re-seed without dropping databases |
| `npm run dev` | **Everything**: 8 services + 3 MCP servers + assistant + web + chat |
| `npm run dev:services` | Only the 7 domain services + gateway |
| `npm run dev:mcp` | The three MCP servers |
| `npm run dev:assistant` / `dev:web` / `dev:chat` | One part |
| `npm run smoke:mcp` | Test the MCP servers (19 checks) |
| `npm run mcp:standalone` | Only what the MCP servers need + all three MCP servers + MCP Inspector web UI |
| `npm run mcp:inspector` / `mcp:inspect:catalog|promotions|account` / `mcp:cli` | MCP Inspector web UI (all servers / one server) or its CLI |
| `npm run typecheck` | `tsc -b` over all backend packages |
| `npm run rag:prepare` / `rag:ingest` | RAG data pipeline |
| `npm run research:html` | Re-render `research/*.md` to HTML |
| `node scripts/smoke/api-smoke.mjs` | End-to-end API test (modifies data) |

### How `npm run dev` fans out

```
npm run dev
 └─ concurrently  (one terminal, coloured prefixes per process)
     ├─ npm run dev:services
     │    └─ concurrently
     │        ├─ npm run dev -w @tf/customer   → tsx watch … src/index.ts   :4001
     │        ├─ npm run dev -w @tf/catalog    → …                          :4002
     │        ├─ …inventory, order, payment, promotion, marketing           :4003–4007
     │        └─ npm run dev -w @tf/gateway                                 :3000
     ├─ npm run dev:mcp
     │    └─ concurrently: mcp-catalog :4201 · mcp-promotions :4202 · mcp-account :4203
     ├─ npm run dev:assistant                                               :4100
     ├─ npm run dev:web    → next dev -p 5173
     └─ npm run dev:chat   → vite --port 5174
```

- `-w @tf/order` (short for `--workspace=@tf/order`) means "run this command **inside** that package". npm switches into its folder and uses its `scripts`.
- `concurrently` runs several commands in one terminal. Each line is prefixed with a name (`[ord]`, `[gw]`…). **Ctrl+C stops all of them.**
- `"npm:dev -w @tf/customer"` is concurrently's shorthand for `npm run dev -w @tf/customer`.

### Each package's own scripts

| Script | Backend services | `apps/web` | `apps/chat` |
|---|---|---|---|
| `dev` | `tsx watch --conditions=development --env-file-if-exists=../../.env src/index.ts` | `next dev -p 5173` | `vite --port 5174` |
| `build` | `tsc -b` | `next build` | `tsc --noEmit && vite build` |
| `start` | `node --env-file-if-exists=../../.env dist/index.js` (needs a build) | `next start -p 5173` | (static files; serve `dist/`) |
| `typecheck` | via root `npm run typecheck` | `tsc --noEmit` | `tsc --noEmit` |

## 8. Day-to-day recipes

### Run or restart one service
```bash
npm run dev -w @tf/order          # just the order service
```
If the whole stack is running under `npm run dev`, you don't restart anything: `tsx watch`, Next and Vite reload on save.

### Add a dependency to ONE package
```bash
npm install zod -w @tf/order                 # runtime dependency
npm install -D @types/uuid -w @tf/order      # dev dependency
npm install marked -w @tf/chat-ui
```
This updates that package's `package.json` and the root lockfile. **Always run from the root with `-w`**, not by `cd`-ing into the folder.

### Add a tool to the whole repo (root dev dependency)
```bash
npm install -D prettier                      # no -w → goes into the root package.json
```

### Remove or upgrade
```bash
npm uninstall pg -w @tf/catalog
npm install next@latest -w @tf/web
npm outdated --workspaces                    # what's out of date, per package
```

### Run a script in several packages
```bash
npm run build --workspaces --if-present      # every package that has a "build" script
npm run typecheck -w @tf/web -w @tf/chat     # several specific packages
```

### See which packages use something
```bash
npm ls @tf/shared                            # who depends on our shared package
npm ls express                               # where express is installed / which versions
```

### Add a new microservice (example: `reviews` on port 4008)
1. Copy a small service as a template: `cp -R services/payment services/reviews`, then delete its `dist/` and `migrations/` contents.
2. In `services/reviews/package.json` set `"name": "@tf/reviews"`.
3. Register it in `packages/shared/src/config.ts` → `SERVICES` (`reviews: { port: 4008, db: 'tf_reviews' }`) and add `REVIEWS_URL` + a client in `client.ts`. The db scripts read `SERVICES`, so `db:reset` will create `tf_reviews` automatically.
4. Write `services/reviews/migrations/001_init.sql` and the routes in `src/index.ts` (`createService('reviews')`).
5. Add `{ "path": "services/reviews" }` to the root `tsconfig.json` references.
6. Add it to the root `dev:services` script (`"npm:dev -w @tf/reviews"`).
7. Expose public routes through `services/gateway`.
8. `npm install` (creates the `@tf/reviews` symlink), then `npm run db:reset` or `db:migrate`, `npm run typecheck`, `npm run dev`.
9. Update `research/architecture.md` (ports, contract).

### Add a new shared front-end or backend library
Create `packages/<name>/package.json` (name `@tf/<name>`, `"private": true`, an `exports` field), run `npm install`, then add `"@tf/<name>": "*"` to the packages that use it (or `npm install @tf/<name> -w <consumer>`).

## 9. Troubleshooting

| Symptom | Cause → fix |
|---|---|
| `Cannot find package '@tf/shared'` | Workspace symlinks missing → run `npm install` at the root |
| A service runs old shared code / `dist` not found | Started with `node dist/…` without building → use `npm run dev`, or run `npm run typecheck` first |
| `ERR_UNKNOWN_FILE_EXTENSION ".ts"` from `@tf/shared` | Run with plain `node` but no `development` condition → use the `dev` script (tsx with `--conditions=development`) |
| `EADDRINUSE: :4004` | Something already listens there → `lsof -nP -iTCP:4004 -sTCP:LISTEN`, stop it, or you already have `npm run dev` running |
| Type errors appear only in `tsc -b` | Editors check files one at a time; `tsc -b` checks everything → trust `npm run typecheck` |
| Next.js can't compile `@tf/chat-ui` | It must be in `transpilePackages` (it is) |
| `npm warn allow-scripts …` during install | npm 11 doesn't run third-party install scripts until approved. Our stack doesn't need them; `npm approve-scripts` lists them if a package ever does |
| A second `package-lock.json` appeared inside a package | Someone ran `npm install` inside that folder → delete it, run `npm install` from the root |
| Weird dependency state | `rm -rf node_modules */*/node_modules && npm install` (the lockfile keeps versions the same) |
| Services can't reach Postgres | `npm run db:up`; check `docker ps` shows `trailforge-postgres` healthy |

## 10. Cheat sheet

```bash
# setup
npm install && npm run db:up && npm run db:reset

# run
npm run dev                       # everything
npm run dev -w @tf/order          # one package
npm run dev:web                   # storefront only (needs services running)

# deps
npm install <pkg> -w @tf/<name>   # add to one package
npm install -D <pkg>              # add a root tool
npm ls <pkg>                      # who uses it

# quality
npm run typecheck                 # backend (tsc -b)
npm run typecheck -w @tf/web      # a front-end
node scripts/smoke/api-smoke.mjs  # API end to end (changes data)

# data
npm run db:migrate                # safe: new migrations only
npm run db:reset                  # destructive: recreate + seed
```

## 11. Why a monorepo for this project?

| Benefit | In TrailForge |
|---|---|
| Change a contract and its callers in **one commit** | Changing order statuses touched shared types, the order service, the seed, the web app and RAG docs together |
| Share code without publishing packages | `@tf/shared` (auth, db, pricing) and `@tf/chat-ui` |
| One install, one lockfile, one set of versions | Every service uses the same `express`, `pg`, `zod` |
| One command to run the whole system | `npm run dev` |

The trade-off: services are still **deployed separately** (each becomes its own container on Azure, the web app goes to Vercel). The monorepo is about how we *develop*, not how we *deploy*. Deployment details are in [Deployment Plan](deployment-plan.md).
