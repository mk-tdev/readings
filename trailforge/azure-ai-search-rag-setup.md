# Azure AI Search for RAG: Setup Guide

> What Azure AI Search is, how it powers RAG (retrieval-augmented generation), and how to set it up for TrailForge in the **portal** or with the **CLI**: create the service, grant access, build the two indexes from our Markdown, test queries, and wire it into the assistant.
> Prerequisite: [Azure OpenAI Setup](azure-openai-setup.md) is done (we need the `text-embedding-3-small` deployment).
> Prefer to see every piece in the portal first (no code)? Do [RAG in the Azure Portal](azure-ai-search-portal-rag.md), then come back here for the app's indexes.

## 1. RAG in one picture

An LLM doesn't know TrailForge's return policy or product specs. **RAG** fixes that by *retrieving* the right passages at question time and putting them in the prompt.

```
 OFFLINE (once, and whenever docs change)            ONLINE (every question)
 ────────────────────────────────────────            ────────────────────────────────────────────
 rag/knowledge/*.md  rag/products/*.md               "Can I return a GPS watch after 45 days?"
        │ 1. load                                            │ 1. embed the question
        │ 2. chunk (on ## headings, ~900 chars)              │ 2. search the index (keyword + vector)
        │ 3. embed each chunk → 1536 numbers                 │ 3. top passages → into the prompt
        │ 4. upload text + vector + metadata                 │ 4. model answers, citing sources
        ▼                                                    ▼
   Azure AI Search index  ◄──────────── query ─────────── assistant (search tool)
```

**Azure AI Search** is the "search the index" part: a managed search engine that stores your chunks and finds the best ones by **keywords**, by **meaning (vectors)**, or **both (hybrid)**, then can **re-rank** them with a semantic model.

## 2. Concepts you need

| Concept | What it is | TrailForge |
|---|---|---|
| **Search service** | The Azure resource (endpoint `https://<name>.search.windows.net`) | One service |
| **Index** | A table of documents with a schema | `tf-knowledge` (policies, guides, FAQs) and `tf-products` (one doc per product chunk) |
| **Document** | One row; for RAG, one **chunk** | `returns-and-refunds-3` = 4th chunk of the returns policy |
| **Field attributes** | `searchable` (full-text), `filterable`, `sortable`, `facetable`, `key` | `category`, `priceCents` filterable on products |
| **Keyword search (BM25)** | Classic ranking: rare query words that appear often in a chunk score high | Great for exact terms ("FALLTRAIL20", "3L shell") |
| **Vector search (HNSW)** | Each chunk's embedding is stored; the query embedding finds the *nearest meanings* (cosine) | "Can I send back my headlamp?" finds "Electronics: 30 days" |
| **Hybrid search** | Run both, then merge with **Reciprocal Rank Fusion (RRF)** | Our default for RAG: robust to both exact codes and paraphrases |
| **Semantic ranker** | A Microsoft re-ranking model that re-orders the top results by how well they answer the question; can also return captions | Optional on top of hybrid (`queryType: semantic`) |
| **Filters** | OData expressions applied before/with ranking | `category eq 'tents' and priceCents le 40000` |

**Why two indexes?** Products and policies are different shapes: products need filters (category, brand, price, tags) and are re-generated from `data/products.json`, while knowledge docs are handwritten prose. Separate indexes keep schemas simple and let the agent pick the right one.

**What we never index:** live stock, live prices, orders, customer data, customer reviews (user-written text, so a prompt-injection risk). Live facts come from service APIs or MCP tools at answer time.

## 3. TrailForge's index schema (from `scripts/rag/src/ingest.ts`)

| Field | Type | Attributes | Both indexes? |
|---|---|---|---|
| `id` | String | **key**, filterable | ✓ (`<file-slug>-<chunkIndex>`) |
| `source` | String | filterable, facetable | ✓ (file name, used for citations) |
| `title` | String | searchable | ✓ (the doc's `# Title`) |
| `section` | String | searchable | ✓ (the chunk's `## Heading`) |
| `chunkIndex` | Int32 | | ✓ |
| `content` | String | searchable | ✓ (the chunk text the model reads) |
| `contentVector` | Collection(Single), **1536 dims** | vector profile `vprofile` (HNSW, cosine) | ✓ |
| `slug`, `category`, `brand` | String | filterable (+ facetable) | products only |
| `priceCents` | Int32 | filterable, sortable | products only |
| `tags` | Collection(String) | filterable, facetable | products only |

- **Semantic configuration** `semantic`: title field `title`, content field `content`, keywords field `section`.
- **Chunking:** split on `##` headings, pack paragraphs up to ~900 characters with ~150 characters of overlap, keep the heading with each chunk. The text embedded is `title — section` + the chunk, so short chunks keep their context.

## 4. Pick a tier

| Tier | Cost | Limits | Semantic ranker | Use when |
|---|---|---|---|---|
| **Free** | $0 | 1 per subscription, 50 MB storage, 3 indexes, shared compute | May not be available; check the portal | Learning; TrailForge's ~1,000 chunks fit |
| **Basic** | ≈ $75 / month (billed hourly) | 2 GB per partition, dedicated | ✓ (free plan up to a monthly query limit) | You want the semantic ranker or more headroom |

Our 2 indexes × about 1,000 chunks × 1536-number vectors come to only a few MB. If the semantic ranker isn't available on your tier, just don't use `queryType: semantic`. Hybrid works on every tier.

## 5. Set up in the Azure portal

1. **Create the service.** Portal → *Create a resource* → **Azure AI Search** → *Create*:
   - Resource group `rg-trailforge` (same as Azure OpenAI), region **East US 2** (same region keeps latency low)
   - Service name `trailforge-search-<unique>` → endpoint `https://trailforge-search-<unique>.search.windows.net`
   - Pricing tier **Free** or **Basic** → *Review + create*.
2. **Enable Entra ID (keyless) access.** Service → *Settings → Keys* → **API access control**: choose **Both** (role-based access control *and* API keys) → *Save*. This lets our code use `az login` / Managed Identity while keys still work for quick tests.
3. **Enable the semantic ranker** (Basic+). Service → *Settings → Semantic ranker* → **Free** plan → *Save*.
4. **Grant yourself roles.** Service → *Access control (IAM)* → *Add role assignment*:
   - **Search Service Contributor**: create and update indexes (the ingest script does this)
   - **Search Index Data Contributor**: upload and query documents

   Assign both to your user, then allow ~5–10 minutes. (On Azure, the assistant's Managed Identity only needs **Search Index Data Reader**.)
5. **Copy the endpoint** from the service *Overview* (the **Url**).

## 6. The same setup with the Azure CLI

```bash
RG=rg-trailforge
LOC=eastus2
SEARCH=trailforge-search-$RANDOM                     # globally unique
SKU=free                                              # or: basic

# Service with keys AND Entra ID accepted (401 + bearer challenge for bad tokens)
az search service create -g $RG -n $SEARCH -l $LOC --sku $SKU \
  --auth-options aadOrApiKey --aad-auth-failure-mode http401WithBearerChallenge

# Basic+: turn on the semantic ranker's free plan
[ "$SKU" != free ] && az search service update -g $RG -n $SEARCH --semantic-search free

# Roles for YOU (create indexes + read/write documents)
SCOPE=$(az search service show -g $RG -n $SEARCH --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee $ME --role "Search Service Contributor" --scope $SCOPE
az role assignment create --assignee $ME --role "Search Index Data Contributor" --scope $SCOPE

echo "AZURE_SEARCH_ENDPOINT=https://$SEARCH.search.windows.net"
```

## 7. Configure TrailForge and build the indexes

Root `.env`:
```bash
AZURE_SEARCH_ENDPOINT=https://trailforge-search-xyz.search.windows.net
AZURE_SEARCH_API_KEY=                     # leave EMPTY → Entra ID via az login
AZURE_SEARCH_PRODUCTS_INDEX=tf-products
AZURE_SEARCH_KNOWLEDGE_INDEX=tf-knowledge
# and from the Azure OpenAI guide:
AZURE_OPENAI_ENDPOINT=https://trailforge-openai-xyz.openai.azure.com
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
```

Run the pipeline:
```bash
npm run rag:prepare     # data/products.json → rag/products/*.md (114 docs, with front-matter metadata)
npm run rag:ingest      # for each index: createOrUpdateIndex → chunk → embed (batches of 16) → upload (batches of 500)
```
Expected output: `▶ tf-products ← rag/products … ✓ N chunks uploaded`, then the same for `tf-knowledge`.

**Re-running** is safe: `createOrUpdateIndex` keeps the schema and `mergeOrUploadDocuments` updates chunks by `id`. **But** chunks that no longer exist (a doc got shorter, a file was deleted) are *not* removed. When docs shrink or are renamed, delete the index and ingest again:
```bash
TOKEN=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
curl -X DELETE "$AZURE_SEARCH_ENDPOINT/indexes/tf-knowledge?api-version=2024-07-01" -H "Authorization: Bearer $TOKEN"
npm run rag:ingest
```

## 8. Test queries

### In the portal
Service → *Indexes* → `tf-knowledge` → **Search explorer**. Try `return window electronics`, then switch to *JSON view* to add `"select": "source,section,content", "top": 3`.

### With the REST API
```bash
TOKEN=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
Q() { curl -s "$AZURE_SEARCH_ENDPOINT/indexes/$1/docs/search?api-version=2024-07-01" \
        -H "Authorization: Bearer $TOKEN" -H "content-type: application/json" -d "$2" | jq '.value[] | {source, section, score: .["@search.score"]}'; }

# 1. keyword (BM25)
Q tf-knowledge '{"search":"refund amount promo code tax","top":3,"select":"source,section"}'

# 2. semantic re-ranking (Basic+)
Q tf-knowledge '{"search":"can I send back my headlamp after six weeks?","queryType":"semantic","semanticConfiguration":"semantic","top":3,"select":"source,section"}'

# 3. filters on products
Q tf-products '{"search":"waterproof","filter":"category eq '\''tents'\'' and priceCents le 40000","top":5,"select":"source,section"}'
```

**Vector and hybrid queries** need the query's embedding (1536 numbers), so they're easiest in code (next section). Our index doesn't define an integrated vectorizer, so the search service won't embed text for you. That's deliberate: we control the embedding model in one place.

### Compare keyword vs vector vs hybrid (good exercise)
Ask the same 5 questions three ways, note the top-3 `source` each time:
- *"FALLTRAIL20"*: keyword wins (an exact code).
- *"my boots got wet, how do I dry them?"*: vector wins (paraphrase of the care guide).
- Hybrid should be at least as good as the better of the two for most questions. That's why RAG uses it.

## 9. Use it from the assistant (agentic RAG)

The assistant is a separate app that may not call the store's APIs, so **all product discovery and policy answers come from these indexes**. Two tools in `services/assistant/src/rag.ts` query them:

| Tool | Index | What it does |
|---|---|---|
| `search_catalog` | `tf-products` | Hybrid search + optional filters (`category`, `brand`, `minPriceDollars`, `maxPriceDollars`, `tag`). An **empty query** browses and returns **product counts per category** (a facet), which is how "list all products" works. Several chunks per product → keeps the best chunk per `slug`. Returns name, brand, list price (snapshot), slug and `[source#chunk]`. |
| `search_knowledge` | `tf-knowledge` | Hybrid search over policies, guides and FAQs; returns passages with `[source#chunk]` ids to cite. |

How a query runs:
```ts
const vector = await embed(query);                                  // same provider/model as rag:ingest
const res = await client.search(query || '*', {
  top, filter,                                                      // e.g. "category eq 'tents' and priceCents le 40000"
  facets: ['category,count:20'],                                    // product counts per category
  vectorSearchOptions: { queries: [{ kind: 'vector', vector, fields: ['contentVector'], kNearestNeighborsCount: 50 }] }, // → hybrid (RRF)
  queryType: 'semantic', semanticSearchOptions: { configurationName: 'semantic' },                                    // re-rank when available
});
```
- If the semantic ranker isn't enabled (e.g. Free tier), the first call fails once and the tool switches to plain hybrid automatically. Set `AZURE_SEARCH_SEMANTIC=false` to skip trying.
- If `AZURE_SEARCH_ENDPOINT` is empty, both tools return `SEARCH_UNAVAILABLE` and the agent says search is temporarily unavailable. It never guesses.
- **Live data stays live:** the list price in the index is a snapshot. For "is size 10 in stock right now?" or the exact current price, the agent uses the store's MCP catalog tools `check_stock` / `get_product` with the slug from `search_catalog`.
- `GET /api/admin/assistant/status` → `rag: { configured, endpoint, indexes, embeddings }`.

**Why tools ("agentic RAG") instead of always stuffing passages into the prompt?**
- The agent decides *when* it needs which index, can rephrase and search again, and combines RAG with live MCP data ("is this tent in stock *and* can I return it?").
- Guardrails attach naturally: relevance cutoff, injection scan on returned chunks, citation checks (Phase 8).

## 10. Security, cost and operations

- **Keyless everywhere:** your user locally, the assistant's Managed Identity on Azure (**Search Index Data Reader**), the ingest job's identity (**Search Index Data Contributor** + **Search Service Contributor**). Disable API keys later (`--disable-local-auth`) once everything uses Entra ID.
- **Network:** public endpoint is fine for learning; production can use a private endpoint inside the Container Apps VNet.
- **Cost:** Free = $0; Basic ≈ $75/month billed hourly. **Delete the service** (or the resource group) when you stop practising. Embedding ~1,000 chunks costs fractions of a cent.
- **Freshness:** re-run `rag:prepare` + `rag:ingest` whenever docs or products change (on Azure: the `rag-ingest` job in the deployment plan).

## 11. Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `403 Forbidden` creating the index | Missing **Search Service Contributor** | Assign it; wait 5–10 min |
| `403` uploading or querying | Missing **Search Index Data Contributor/Reader**, or API access control set to "API keys" only | Assign the role; set access control to **Both** (or RBAC) |
| `401` with a bearer token | Token for the wrong resource | Use `--resource https://search.azure.com` |
| `The vector field 'contentVector' … dimensions` | Embedding model ≠ 1536 dims | Use `text-embedding-3-small` (1536) or change `DIMS` and recreate the index |
| `Semantic search is not enabled` | Free tier / ranker off | Enable the semantic ranker (Basic+), or drop `queryType: semantic` |
| Old text still returned after editing a doc | Removed chunks aren't deleted by re-ingest | Delete the index and ingest again (§7) |
| `429` during ingest | Embedding TPM exceeded | Re-run (it's idempotent), or raise the embedding deployment's capacity |
| Index schema change fails (`CannotChangeExistingField`) | Existing fields can't change type | Delete the index and ingest again |
| Poor results | Chunks too big/small, missing headings | Check `rag/knowledge` docs have `##` sections; compare keyword/vector/hybrid (§8) |

## 12. Checklist

- [ ] Search service created (Free or Basic) in the same region as Azure OpenAI
- [ ] API access control set to **Both** (or RBAC); semantic ranker enabled if Basic
- [ ] Roles: **Search Service Contributor** + **Search Index Data Contributor** for me
- [ ] `.env` filled (`AZURE_SEARCH_ENDPOINT`, index names, embedding deployment)
- [ ] `npm run rag:prepare && npm run rag:ingest` uploaded both indexes
- [ ] Search explorer + REST keyword/semantic/filter queries return sensible chunks
- [ ] Compared keyword vs vector vs hybrid on 5 questions
- [ ] Ask the assistant "list all products", "tents under $400", "return window for electronics?" and check the `search_catalog` / `search_knowledge` tool cards
- [ ] Next: RAG guardrails (Phase 8)

Related: [Azure OpenAI Setup](azure-openai-setup.md) · [Implementation Plan](implementation-plan.md) (Phases 4, 5, 8) · [Deployment Plan](deployment-plan.md) · [MCP Guide](mcp-guide.md)
