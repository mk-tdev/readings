# RAG in the Azure Portal: Hands-on Walkthrough

> Build a working RAG index **entirely in the Azure portal**, with no code, to see every moving part before using TrailForge's script (`npm run rag:ingest`).
> You'll upload TrailForge's policy documents to Blob Storage, let Azure AI Search **chunk and embed them for you** ("integrated vectorization"), test keyword, vector and hybrid queries, then compare the result with what the script builds.
> Prerequisites: an Azure OpenAI resource with a **`text-embedding-3-small`** deployment ([Azure OpenAI Setup](azure-openai-setup.md)). Time: about 45 minutes.

## 1. What you'll build, and how it maps to the script

```
 Blob Storage container "tf-knowledge-docs"         Azure AI Search
 ┌──────────────────────────┐   ┌─────────────────────────────────────────────────────────┐
 │ returns-and-refunds.md   │   │ Data source ─► Indexer ─► Skillset ──────────► Index     │
 │ shipping-policy.md       │──►│ (where files   (runs the   1. Split skill      tf-portal- │
 │ … 51 .md files           │   │  live)          pipeline)     (chunks)         knowledge  │
 └──────────────────────────┘   │                             2. Azure OpenAI    + vectorizer│
                                │                                Embedding skill (for queries)│
                                └─────────────────────────────────────────────────────────┘
```

| RAG step | Portal (this guide): **pull model** | TrailForge script: **push model** |
|---|---|---|
| Load | **Data source** + **indexer** read files from Blob Storage | `ingest.ts` reads `rag/knowledge/*.md` from disk |
| Chunk | **Split skill** (fixed-size pages with overlap) | `chunkMarkdown()`: split on `##` headings, ~900 chars, 150 overlap |
| Embed | **Azure OpenAI Embedding skill**, run by Azure AI Search | The script calls the embeddings API itself |
| Store | Index created by the wizard | Index schema defined in `ingest.ts` |
| Query embedding | **Vectorizer** on the index: Azure AI Search embeds the question for you | The app embeds the question, then sends the vector |
| Refresh | Re-run the **indexer** (it picks up new/changed blobs) | Re-run `npm run rag:ingest` |

Both are valid RAG designs. The portal shows the managed, no-code version; the script gives you full control of chunking and fields (and filterable product metadata).

## 2. Create the Azure AI Search service (skip if you have one)

1. Portal → **Create a resource** → **Azure AI Search** → *Create*.
2. Resource group: the same one as Azure OpenAI (e.g. `rg-trailforge`). Region: preferably the same as Azure OpenAI.
3. Name: `trailforge-search-<unique>`. Pricing tier: **Free** (1 per subscription; up to 3 indexes and 3 indexers) or **Basic** (semantic ranker).
4. *Review + create* → *Create*. Wait about 1–2 minutes.
5. Open it → **Settings → Keys** → *API access control*: **Both** (role-based access and API keys).
6. *(Basic+)* **Settings → Semantic ranker** → **Free** plan → *Save*.

## 3. Put the documents in Blob Storage

### 3.1 Create a storage account
Portal → **Create a resource** → **Storage account**:
- Same resource group and region; name `trailforgerag<unique>` (lowercase letters and digits only)
- Performance **Standard**, Redundancy **LRS** (cheapest) → *Review + create*.

### 3.2 Create a container and upload
1. Storage account → **Data storage → Containers** → **+ Container** → name **`tf-knowledge-docs`**, access level **Private** → *Create*.
2. Open the container → **Upload** → select all files in `trailforge/rag/knowledge/` (51 `.md` files) → *Upload*.

CLI alternative (same result):
```bash
az storage container create --account-name <storage> -n tf-knowledge-docs --auth-mode login
az storage blob upload-batch --account-name <storage> -d tf-knowledge-docs -s rag/knowledge --pattern "*.md" --auth-mode login
```
(`--auth-mode login` needs the **Storage Blob Data Contributor** role on the storage account for your user.)

> Why only the knowledge docs? `rag/products/*.md` files start with front matter (`category:`, `priceCents:`…). The wizard indexes that as plain text, so you can't **filter** by category or price. That's exactly why the app's product index is built by the script. You can still upload products to a second container later to compare.

## 4. Let Azure AI Search reach Storage and Azure OpenAI

The indexer runs **as the search service**, so the search service needs permission to read blobs and to call the embedding model. Two options:

| Option | Steps | Use when |
|---|---|---|
| **API keys** (quickest) | In the wizard, pick the storage connection string and the Azure OpenAI **API key** authentication | First try / learning |
| **Managed identity** (recommended) | ① Search service → **Settings → Identity** → *System assigned*: **On** → *Save*. ② Storage account → **Access control (IAM)** → *Add role assignment* → **Storage Blob Data Reader** → *Managed identity* → your search service. ③ Azure OpenAI resource → **Access control (IAM)** → **Cognitive Services OpenAI User** → your search service. Wait ~5–10 min. | No secrets stored anywhere |

## 5. Run the "Import data" wizard

> The wizard's name and layout change over time (you may see **Import data (new)**, **Import and vectorize data**, or a tile on the service *Overview*). The steps below are the same ideas in any version.

Search service → **Overview** → **Import data (new)** (or *Import and vectorize data*):

1. **Data source:** **Azure Blob Storage**.
2. **Scenario:** **RAG** (sometimes "Retrieval-augmented generation" or "Text"; not "Multimodal").
3. **Connect to your data:**
   - Subscription, storage account `trailforgerag…`, container **`tf-knowledge-docs`**.
   - Authentication: managed identity (if you did §4) or key.
   - Leave *deletion tracking* off for now.
4. **Vectorize your text:**
   - Kind: **Azure OpenAI** (or *Azure AI Foundry*), your resource, model deployment **`text-embedding-3-small`**.
   - Authentication: **system-assigned identity** (if you did §4) or **API key**.
   - Tick the acknowledgement that embedding calls are billed by Azure OpenAI.
5. **Vectorize images:** skip.
6. **Advanced settings:**
   - **Enable semantic ranker** if you're on Basic+.
   - Schedule: **Once**.
7. **Review and create:**
   - Objects name prefix **`tf-portal-knowledge`**. This keeps it separate from the app's `tf-knowledge` index.
   - *Create*.

The wizard creates four objects, all named after the prefix: a **data source**, a **skillset**, an **index** and an **indexer**. The indexer starts immediately.

## 6. Watch the indexer run

Search service → **Search management → Indexers** → `tf-portal-knowledge-indexer`:
- **Status** goes *In progress* → *Success*; *Docs succeeded* should be **51**.
- Open the run to see warnings/errors per document (e.g. a file that failed to embed because of throttling).

Then **Indexes** → `tf-portal-knowledge`:
- **Document count** is the number of **chunks** (several per file), not 51.
- Storage size is a few MB.

## 7. Look at what the wizard built (this is the learning part)

Open each object in the portal and read its **JSON** (every object has an *Edit JSON* / *JSON* view):

| Object | What to look for |
|---|---|
| **Data source** `tf-portal-knowledge-datasource` | `type: azureblob`, the container name, the credentials (identity or connection string) |
| **Skillset** `tf-portal-knowledge-skillset` | `#Microsoft.Skills.Text.SplitSkill`: `textSplitMode: pages`, `maximumPageLength` (about 2000), `pageOverlapLength` (about 500), so fixed-size chunks with overlap. `#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill`: your deployment and `dimensions` 1536. **Index projections**: one source file → many chunk documents |
| **Index** `tf-portal-knowledge` | Fields like `chunk_id` (key), `parent_id` (the file), `chunk` (text), `title` (file name), `text_vector` (1536-dim vector). The **vectorizer** under *Vector profiles*. The semantic configuration |
| **Indexer** `tf-portal-knowledge-indexer` | Links data source → skillset → index; `fieldMappings`, `outputFieldMappings`; schedule; run history |

Compare with TrailForge's script index (`scripts/rag/src/ingest.ts`):

| | Portal wizard index | Script index `tf-knowledge` |
|---|---|---|
| Chunk boundaries | Fixed size (~2000 chars, ~500 overlap); can cut mid-section | `##` headings first, ~900 chars, keeps the heading with each chunk |
| Fields | `chunk_id`, `parent_id`, `chunk`, `title`, `text_vector` | `id`, `source`, `title`, `section`, `chunkIndex`, `content`, `contentVector` |
| Section heading per chunk | ✗ | ✓ (`section`; used in citations and as semantic keywords) |
| Who embeds queries | The index's **vectorizer** | The app (same model) |
| Product filters (category, brand, price, tags) | ✗ (front matter is just text) | ✓ (`tf-products`) |

## 8. Query it in Search explorer

Index `tf-portal-knowledge` → **Search explorer**:

1. **Keyword:** type `return window electronics` → *Search*. Results ranked by BM25.
2. Switch to **JSON view** and try each of these:

```json
{ "search": "refund amount when I used a promo code", "select": "title, chunk", "top": 3 }
```

**Vector only** (the vectorizer embeds your text; no keyword match needed):
```json
{
  "select": "title, chunk",
  "vectorQueries": [{ "kind": "text", "text": "can I send back my headlamp after six weeks?", "fields": "text_vector", "k": 3 }]
}
```

**Hybrid** (keyword + vector, merged with RRF):
```json
{
  "search": "headlamp return after six weeks",
  "select": "title, chunk",
  "top": 3,
  "vectorQueries": [{ "kind": "text", "text": "headlamp return after six weeks", "fields": "text_vector", "k": 50 }]
}
```

**Hybrid + semantic ranker** (Basic+; use the semantic configuration name shown on the index, usually `tf-portal-knowledge-semantic-configuration`):
```json
{
  "search": "headlamp return after six weeks",
  "select": "title, chunk",
  "top": 3,
  "queryType": "semantic",
  "semanticConfiguration": "tf-portal-knowledge-semantic-configuration",
  "captions": "extractive",
  "answers": "extractive",
  "vectorQueries": [{ "kind": "text", "text": "headlamp return after six weeks", "fields": "text_vector", "k": 50 }]
}
```

Things to notice:
- `"FALLTRAIL20"` → keyword wins (an exact code). `"my boots got soaked, how do I dry them?"` → vector wins (a paraphrase of the care guide).
- With semantic ranking you get `@search.rerankerScore`, **captions** (the best sentences) and sometimes an **answer**.
- Field names are the wizard's (`chunk`, `text_vector`), not the script's.

### The same query with curl (Entra ID)
```bash
SEARCH=https://trailforge-search-xyz.search.windows.net
TOKEN=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
curl -s "$SEARCH/indexes/tf-portal-knowledge/docs/search?api-version=2024-07-01" \
  -H "Authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d '{"search":"headlamp return","select":"title,chunk","top":3,
       "vectorQueries":[{"kind":"text","text":"headlamp return","fields":"text_vector","k":50}]}' | jq '.value[] | {title, score: ."@search.score"}'
```
(Querying with Entra ID needs **Search Index Data Reader** or Contributor on the search service for your user.)

## 9. Change a document and re-index (the pull model in action)

1. Edit `rag/knowledge/gift-cards.md` (e.g. add a sentence), upload it again to the container (overwrite).
2. Indexers → `tf-portal-knowledge-indexer` → **Run**.
3. Only the changed blob is processed (*Docs succeeded: 1*). Query for your new sentence.

Notes:
- **Deleted files** stay in the index unless you enable *deletion tracking* (blob soft delete or a metadata flag) in the data source.
- A **schedule** (e.g. hourly) keeps the index in sync automatically.

## 10. Connect it to TrailForge? Use the script for the app

The assistant's RAG tools (`services/assistant/src/rag.ts`) expect the **script's schema** (`content`, `contentVector`, `source`, `section`, product filter fields) and the index names `tf-knowledge` / `tf-products`. The portal index uses different field names and has no product filters. So:

1. Keep `tf-portal-knowledge` as your **learning index** (compare queries side by side).
2. Build the **app's** indexes with the script, using the same search service:
   ```bash
   # .env
   AZURE_SEARCH_ENDPOINT=https://trailforge-search-xyz.search.windows.net
   AZURE_OPENAI_ENDPOINT=https://<your-openai>.openai.azure.com
   AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
   EMBEDDING_PROVIDER=azure          # match the provider you'll use for queries
   npm run rag:prepare && npm run rag:ingest
   ```
3. Your Free tier fits all three: `tf-portal-knowledge`, `tf-knowledge`, `tf-products` (3-index limit). Delete the portal objects later if you need the room.
4. Compare the same question in both indexes. Heading-aware chunks (script) usually give cleaner citations than fixed-size chunks (portal).

## 11. Cost and clean-up

- **Storage:** a few cents per month for 51 small files.
- **Embeddings:** billed by Azure OpenAI per token. All 51 docs plus test queries cost well under $0.10.
- **Search:** Free = $0; Basic ≈ $75/month billed hourly.
- **Clean up the learning objects:** Search service → Indexers / Skillsets / Data sources / Indexes → delete the four `tf-portal-knowledge*` objects. Delete the storage account if you won't re-index.

## 12. Troubleshooting

| Problem | Fix |
|---|---|
| Wizard can't list the storage account or Azure OpenAI resource | Same subscription? You need read access; refresh the wizard |
| Indexer fails: `403` reading blobs | Managed identity: grant the search service **Storage Blob Data Reader** on the storage account (wait 5–10 min), or use a connection string |
| Indexer warnings: embedding `401/403` | Grant the search service **Cognitive Services OpenAI User** on the Azure OpenAI resource, or use API-key auth in the wizard |
| Indexer warnings: `429` | Embedding deployment TPM too low. Raise capacity, then re-run the indexer (only failed docs are retried) |
| `.md` files skipped or unsupported | Some versions read only certain extensions. Rename to `.txt` for the experiment, or check the data source's parsing mode |
| Vector query error `no vectorizer` | The index has no vectorizer (wizard step 4 skipped): re-run the wizard, or query with `kind: "vector"` and your own embedding |
| Semantic query error | Semantic ranker not enabled (Free tier or not turned on) → drop `queryType: semantic` |
| Free tier "quota exceeded" | Free allows 3 indexes/indexers; delete unused objects |

## 13. Checklist

- [ ] Search service (Free or Basic), API access control **Both**
- [ ] Storage account + private container `tf-knowledge-docs` with the 51 knowledge `.md` files
- [ ] Search service can read Storage and call the embedding deployment (keys or managed identity)
- [ ] Wizard run with prefix `tf-portal-knowledge`; indexer *Success*, 51 docs
- [ ] Read the JSON of the data source, skillset, index and indexer
- [ ] Ran keyword, vector, hybrid (and semantic) queries in Search explorer
- [ ] Changed one document and re-ran the indexer
- [ ] Next: `npm run rag:ingest` for the app's `tf-knowledge` / `tf-products` and compare

Related: [Azure AI Search for RAG (script)](azure-ai-search-rag-setup.md) · [Azure OpenAI Setup](azure-openai-setup.md) · [Implementation Plan](implementation-plan.md)
