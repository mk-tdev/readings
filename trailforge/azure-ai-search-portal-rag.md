# RAG in the Azure Portal: Step-by-Step (Free tier)

> Build TrailForge's RAG indexes **entirely in the Azure portal**, with no code, so you see every moving part before using the script (`npm run rag:ingest`).
> Azure AI Search will **read your files from Blob Storage, chunk them, embed them with your Azure OpenAI model, and index them** ("integrated vectorization"). Then you'll query them in Search explorer.
> Written for the **Free** search tier and the resource names below. Time: about 30 minutes.

## 0. The setup this guide uses

| Resource | Name | Notes |
|---|---|---|
| Resource group | `rg-trailforge` | Region **Southeast Asia** for everything |
| Azure OpenAI | `trailforge-openai-devtest` | Deployments `gpt-5-mini` and **`text-embedding-3-small`** (the one RAG needs) |
| Storage account | `trailforgestorage` | Containers **`tf-knowledge-docs`** (51 files from `rag/knowledge/`) and **`tf-products-docs`** (114 files from `rag/products/`) |
| Azure AI Search | `trailforge-search-devtest` | **Free** tier |

Use your own names if they differ; every step says which resource you're on.

**Free tier limits that matter here:** at most **3 indexes, 3 indexers, 3 data sources and 3 skillsets**, and 50 MB of storage. This guide creates **2 of each** (knowledge + products). TrailForge's script later needs 2 more indexes, so you'll delete one portal index first (see §8). No managed identity, semantic ranker or region limits apply to Free for this walkthrough.

## 1. How it works (read once)

```
 trailforgestorage                          trailforge-search-devtest (Azure AI Search)
 ┌────────────────────────┐   ┌───────────────────────────────────────────────────────────────┐
 │ tf-knowledge-docs/*.md │   │  DATA SOURCE ──► INDEXER ──► SKILLSET ──────────────► INDEX     │
 │ tf-products-docs/*.md  │──►│  "where the      "runs the    1. Split skill          chunks +  │
 └────────────────────────┘   │   files are"      pipeline"     (cut into chunks)      vectors  │
                              │                                2. Azure OpenAI ─────► calls     │
                              │                                   Embedding skill      trailforge-│
                              │                                   (1536 numbers/chunk) openai-   │
                              │   INDEX also has a VECTORIZER: it embeds your QUESTION   devtest │
                              │   at query time with the same model                              │
                              └───────────────────────────────────────────────────────────────┘
```

The **indexer runs as the search service**, using its **managed identity**. That identity needs permission to **read blobs** and to **call the embedding model**. That's the only setup between "files uploaded" and "wizard works".

| RAG step | Portal (this guide): pull model | TrailForge script: push model |
|---|---|---|
| Load | Data source + indexer read Blob Storage | `ingest.ts` reads `rag/*` from disk |
| Chunk | Split skill (fixed-size pages + overlap) | `##` headings first, ~900 chars, 150 overlap |
| Embed | Azure OpenAI Embedding skill, called by Search | The script calls the embeddings API |
| Query embedding | The index's **vectorizer** | The app embeds the question |
| Refresh | Re-run the indexer | Re-run `npm run rag:ingest` |

## 2. Configure the search service (✅ already done on `trailforge-search-devtest`)

Check these once on **trailforge-search-devtest**:

| Setting (left menu) | Should be |
|---|---|
| **Settings → Keys** → API access control | **Both** |
| **Settings → Identity** → System assigned | **On**, with an *Object (principal) ID* shown |
| **Settings → Semantic ranker** | **Free** plan (on the Free tier this has a monthly query allowance) |

If any isn't set: change it → **Save**.

## 3. Grant access: the step that makes the wizard work (⬜ to do)

Three role assignments. **A** and **B** are for the search service's identity (the indexer); **C** is for you (Entra ID queries with `curl` and, later, the script).

### A. Search can read your files: on the storage account
1. Open storage account **trailforgestorage** → left menu **Access control (IAM)**.
2. **+ Add** → **Add role assignment**.
3. *Role* tab: search **Storage Blob Data Reader** → select it → **Next**.
4. *Members* tab: *Assign access to* **Managed identity** → **+ Select members**.
5. In the panel: *Managed identity* dropdown **Search service** → click **trailforge-search-devtest** → **Select**.
6. **Review + assign** → **Review + assign**.

### B. Search can call your embedding model: on Azure OpenAI
1. Open **trailforge-openai-devtest** → **Access control (IAM)** → **+ Add** → **Add role assignment**.
2. Role **Cognitive Services OpenAI User** → **Next**.
3. *Assign access to* **Managed identity** → **+ Select members** → *Managed identity* **Search service** → **trailforge-search-devtest** → **Select**.
4. **Review + assign** → **Review + assign**.

### C. You can query and manage the indexes with Entra ID: on the search service
1. Open **trailforge-search-devtest** → **Access control (IAM)** → **+ Add** → **Add role assignment**.
2. Role **Search Index Data Contributor** → **Next** → *Assign access to* **User, group, or service principal** → **+ Select members** → your account → **Select** → **Review + assign**.
3. Repeat with role **Search Service Contributor** (lets the script create indexes later).

Being **Owner** lets you manage the resource, but not read or write the data inside it with Entra ID. That's why C is needed. The portal itself uses the service keys, so Search explorer works even without C.

**Wait 5–10 minutes** after A and B before running the wizard. New roles take a while to apply, and this is the #1 cause of first-run errors.

**Check A and B:** each resource → **Access control (IAM)** → **Role assignments** tab → you should see `trailforge-search-devtest` (type *Search service*) with the role.

## 4. Import the knowledge docs with the wizard (⬜ to do)

On **trailforge-search-devtest** → **Overview** → top toolbar **Import data (new)**.
(If you see only *Import data* or *Import and vectorize data*, use that; the pages are the same ideas.)

| # | Wizard page | What to choose |
|---|---|---|
| 1 | **Choose a data source** | **Azure Blob Storage** |
| 2 | **Choose a scenario** | **RAG** (not Multimodal, not Keyword) |
| 3 | **Configure your data connection** | Subscription **Azure subscription 1** · Storage account **trailforgestorage** · Blob container **tf-knowledge-docs** · Blob folder: empty · Parsing mode **Default** · Tick **Authenticate using managed identity** → identity type **System-assigned** · Leave *Enable deletion tracking* off → **Next** |
| 4 | **Vectorize your text** | Kind **Azure OpenAI** · Subscription **Azure subscription 1** · Azure OpenAI service **trailforge-openai-devtest** · Model deployment **text-embedding-3-small** · Authentication type **System assigned identity** · Tick the acknowledgement that Azure OpenAI is billed separately → **Next** |
| 5 | **Vectorize and enrich your images** | Leave everything off → **Next** |
| 6 | **Advanced settings** | Tick **Enable semantic ranker** · Schedule **Once** → **Next** |
| 7 | **Review and create** | Objects name prefix **`tf-portal-knowledge`** → **Create**. If you skip the prefix, the wizard uses a default like `rag-1792331433006` for all four objects; that works too, just use that name below |

You'll see "Import successfully configured". The wizard created four objects and **the indexer starts immediately**:

| Object | Name |
|---|---|
| Data source | `tf-portal-knowledge-datasource` |
| Skillset | `tf-portal-knowledge-skillset` |
| Index | `tf-portal-knowledge` |
| Indexer | `tf-portal-knowledge-indexer` |

## 5. Import the product docs (⬜ to do)

Run the wizard again with exactly the same choices, except:
- Page 3 → Blob container **tf-products-docs**
- Page 7 → prefix **`tf-portal-products`**

The product `.md` files start with front matter (`category:`, `priceCents:`, `tags:`…). The wizard indexes it as **plain text**, so you can *search* for "tents under 400" but you **can't filter** by category or price. That's the main reason the app's product index is built by the script (§8).

## 6. Check the indexers ran

**trailforge-search-devtest** → left menu **Search management → Indexers**:

| Indexer | Expected |
|---|---|
| `tf-portal-knowledge-indexer` | Status **Success** · Docs succeeded **51** |
| `tf-portal-products-indexer` | Status **Success** · Docs succeeded **114** |

Click an indexer → its run history shows per-document warnings or errors (see §11 if anything failed).

Then **Search management → Indexes**: the *Document count* is the number of **chunks**, which is higher than the file count because each file is split into several chunks.

## 7. Explore what was built, then query it

### 7.1 Read the JSON (the learning part)
Open each object and use its **JSON** / **Edit JSON** view:

| Look at | What to notice |
|---|---|
| **Data sources** → `tf-portal-knowledge-datasource` | `type: azureblob`, container `tf-knowledge-docs`, credentials = a **ResourceId** connection (managed identity, no key) |
| **Skillsets** → `tf-portal-knowledge-skillset` | `#Microsoft.Skills.Text.SplitSkill`: `textSplitMode: pages`, `maximumPageLength` (~2000 chars), `pageOverlapLength` (~500). `#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill`: your deployment, 1536 dimensions. `indexProjections`: **one file → many chunk documents** |
| **Indexes** → `tf-portal-knowledge` → *Fields* | `chunk_id` (key), `parent_id` (the file), `chunk` (text), `title` (file name), `text_vector` (1536-dim) |
| same index → *Vector profiles* | The **vectorizer** pointing at `trailforge-openai-devtest` / `text-embedding-3-small` |
| same index → *Semantic configurations* | Usually `tf-portal-knowledge-semantic-configuration` |
| **Indexers** → `tf-portal-knowledge-indexer` | Links data source → skillset → index; schedule; run history |

### 7.2 Query in Search explorer
**Indexes** → `tf-portal-knowledge` → **Search explorer**.

1. **Keyword:** type `return window electronics` → **Search** (BM25 ranking).
2. Click **View → JSON view** and paste each query below → **Search**.

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

**Hybrid** (keyword + vector, merged with Reciprocal Rank Fusion):
```json
{
  "search": "headlamp return after six weeks",
  "select": "title, chunk",
  "top": 3,
  "vectorQueries": [{ "kind": "text", "text": "headlamp return after six weeks", "fields": "text_vector", "k": 50 }]
}
```

**Hybrid + semantic ranker** (check the semantic configuration name in 7.1):
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

**On the products index** (`tf-portal-products` → Search explorer):
```json
{
  "search": "waterproof tent for two people",
  "select": "title, chunk",
  "top": 5,
  "vectorQueries": [{ "kind": "text", "text": "waterproof tent for two people", "fields": "text_vector", "k": 50 }]
}
```

Things to notice:
- `FALLTRAIL20` → keyword wins (an exact code). `my boots got soaked, how do I dry them?` → vector wins (a paraphrase of the boot care guide). Hybrid is good at both.
- The semantic query adds `@search.rerankerScore`, **captions** and sometimes **answers**.
- Each result is a **chunk**; `title` is the file it came from.

### 7.3 Same query from the terminal (needs role C)
```bash
TOKEN=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
curl -s "https://trailforge-search-devtest.search.windows.net/indexes/tf-portal-knowledge/docs/search?api-version=2024-07-01" \
  -H "Authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d '{"search":"headlamp return","select":"title,chunk","top":3,
       "vectorQueries":[{"kind":"text","text":"headlamp return","fields":"text_vector","k":50}]}' \
  | jq '.value[] | {title, score: ."@search.score"}'
```

### 7.4 Change a document and re-index
1. Edit `rag/knowledge/gift-cards.md` (add a sentence) → upload it to **tf-knowledge-docs** again (overwrite).
2. **Indexers** → `tf-portal-knowledge-indexer` → **Run** → only **1** document is processed.
3. Search for your new sentence.

Deleted files stay in the index unless *deletion tracking* is enabled on the data source.

## 8. Next: the app's index (and the Free-tier limit)

TrailForge's assistant reads the **script's** index **`tf-rag`**: one index for products *and* knowledge, told apart by a filterable `type` field (`product` | `knowledge`). It uses different field names from the wizard (`content`, `contentVector`, `section`…) and real filter fields for products (`category`, `brand`, `priceCents`, `tags`). The portal indexes are your **learning copies**.

Free tier = **3 indexes** (and 3 indexers / data sources / skillsets). The script needs **1**. When you're done exploring, delete the portal objects for each import (indexer → index → skillset → data source) to free the slots:
1. **Indexers** → `…-indexer` → **Delete**.
2. **Indexes** → the portal index → **Delete**.
3. **Skillsets** → `…-skillset` → **Delete**.
4. **Data sources** → `…-datasource` → **Delete**.

Then build the app's index:
```bash
# trailforge/.env
AZURE_OPENAI_ENDPOINT=https://trailforge-openai-devtest.openai.azure.com
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
AZURE_SEARCH_ENDPOINT=https://trailforge-search-devtest.search.windows.net
AZURE_SEARCH_INDEX=tf-rag
EMBEDDING_PROVIDER=azure        # ingest AND queries must use the same embedding provider
npm run rag:prepare && npm run rag:ingest
```
(The script uses your `az login` identity: role **C** on the search service, plus **Cognitive Services OpenAI User** on `trailforge-openai-devtest`, which you already have.) Result: **1 of 3 index slots used**, 954 chunks.

| | Portal (wizard) index | Script `tf-rag` |
|---|---|---|
| Chunks | Fixed size (~2000 chars, ~500 overlap); can cut mid-section | `##` headings first, ~900 chars; keeps the heading with each chunk |
| Fields | `chunk_id`, `parent_id`, `chunk`, `title`, `text_vector` | `id`, `type`, `source`, `title`, `section`, `chunkIndex`, `content`, `contentVector` (+ product fields) |
| Query embedding | The index's vectorizer | The app |
| Product filters | ✗ | ✓ (`type eq 'product' and category eq …`) |
| Indexes used | one per import | one for everything |

**Watch the storage limit too:** the Free tier allows 50 MB per service. `tf-rag` (954 chunks with 1536-number vectors) is the main user of that space.

## 9. Cost

- **Search:** Free = $0.
- **Embeddings:** billed by `trailforge-openai-devtest`; all 165 files plus test queries cost a few cents.
- **Storage:** cents per month.

## 10. Clean up (when finished)

Delete the portal objects in this order: **indexers → indexes → skillsets → data sources** (all `tf-portal-*`). Keep the storage containers if you'll re-index later.

## 11. Troubleshooting

| Symptom (indexer run details) | Cause | Fix |
|---|---|---|
| `403` / `AuthorizationPermissionMismatch` reading blobs | Role **A** missing or not applied yet | Check *trailforgestorage → IAM → Role assignments*; wait 10 min; **Run** the indexer again |
| Embedding skill warnings `401`/`403` | Role **B** missing or not applied yet | Check *trailforge-openai-devtest → IAM*; wait; re-run |
| Embedding skill warnings `429` | Deployment rate limit (TPM) | Re-run (only failed docs retry) or raise the `text-embedding-3-small` capacity |
| Wizard can't list `trailforgestorage` or the OpenAI resource | Different subscription/region filter | Pick *Azure subscription 1*; refresh the wizard |
| "Quota exceeded" / can't create an index | Free tier allows 3 of each object | Delete unused `tf-portal-*` objects (§8 order) |
| `.md` files skipped | Parsing/extension issue | Check the indexer's run details; as an experiment, try parsing mode **Text** or rename a file to `.txt` |
| Vector query error "no vectorizer" | Wizard step 4 not completed | Re-run the wizard with *Vectorize your text* configured |
| Semantic query error | Ranker off or the configuration name is wrong | §2 check; copy the name from the index's *Semantic configurations* |
| `curl` → `401`/`403` | Role **C** missing | §3 C; wait a few minutes; get a new token |

## 12. Checklist

- [ ] §2 Search service: keys **Both**, identity **On**, semantic ranker **Free**
- [ ] §3 Role **A** (Storage Blob Data Reader → search identity on `trailforgestorage`)
- [ ] §3 Role **B** (Cognitive Services OpenAI User → search identity on `trailforge-openai-devtest`)
- [ ] §3 Role **C** (Search Index Data Contributor + Search Service Contributor → you)
- [ ] §4 Wizard for `tf-knowledge-docs` → `tf-portal-knowledge` (51 docs, Success)
- [ ] §5 Wizard for `tf-products-docs` → `tf-portal-products` (114 docs, Success)
- [ ] §7 Read the JSON; ran keyword, vector, hybrid and semantic queries; re-indexed one changed file
- [ ] §8 Deleted the portal objects when done; ran the script to build `tf-rag`

Related: [Azure AI Search for RAG (script)](azure-ai-search-rag-setup.md) · [Azure OpenAI Setup](azure-openai-setup.md) · [Implementation Plan](implementation-plan.md)
