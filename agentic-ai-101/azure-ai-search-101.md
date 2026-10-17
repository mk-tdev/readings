# Azure AI Search 101 — from zero

> A quick, standalone primer. For the deep dive tied to this repo's actual index schema, ingestion pipeline, and hands-on queries, see `guides/07-azure-ai-search.md` (in the agentic-ai course).

## What it is

**Azure AI Search** (formerly "Azure Cognitive Search") is Azure's managed search engine. For AI apps it matters because it does three things in one request:

1. **Keyword search** — classic full-text search (exact terms, names, codes).
2. **Vector search** — similarity search over embeddings (meaning, paraphrase).
3. **Hybrid search** — both at once, merged into a single ranked list — which is the recommended default for **RAG** (Retrieval-Augmented Generation): finding the right chunks of your documents to paste into an LLM's context.

## Core vocabulary

| Concept | Meaning | Analogy |
|---|---|---|
| **Search service** | The Azure resource you provision (tier = capacity + features) | A database server |
| **Index** | A schema of fields + the data structures to search them | A table |
| **Document** | One JSON record in the index | A row |
| **Field attribute** | What you can do with a field | Column constraints |

### Field attributes you'll actually use

- **`key`** — the unique id of a document. Uploading with an existing key **overwrites** it.
- **`searchable`** — full-text indexed (for text) or vector-indexed (for vector fields).
- **`filterable`** — usable in `$filter` expressions, e.g. `source eq 'readme.md'`.
- **`facetable`** — lets you get counts-by-value (like a "category" sidebar).
- **`sortable`** — usable in `$orderby`.

## A minimal index schema

```ts
fields: [
  { name: "id",       type: "Edm.String", key: true },
  { name: "title",    type: "Edm.String", searchable: true },
  { name: "content",  type: "Edm.String", searchable: true },
  { name: "contentVector", type: "Collection(Edm.Single)", searchable: true,
    vectorSearchDimensions: 1536, vectorSearchProfileName: "default-profile" },
],
vectorSearch: {
  algorithms: [{ name: "hnsw", kind: "hnsw", parameters: { metric: "cosine" } }],
  profiles:   [{ name: "default-profile", algorithmConfigurationName: "hnsw" }],
},
```

`Collection(Edm.Single)` is just "an array of 32-bit floats" — a vector. Its dimension **must exactly match** your embedding model's output size (e.g. 1536 for `text-embedding-3-small`).

## The three ways to search

### 1. Keyword search (BM25)

Text fields get tokenized into an inverted index (term → documents). Ranking uses **BM25**: higher score for documents that contain the query terms often, where those terms are rare across the whole index.

Good at: exact terms, codes, acronyms, names. Bad at: synonyms, paraphrases ("car" won't match "automobile").

### 2. Vector search (HNSW)

The query text is embedded into a vector; the service finds the nearest document vectors by similarity. Scanning every vector would be slow at scale, so the index builds an **HNSW** graph (Hierarchical Navigable Small World) — a layered graph that lets search hop toward nearby vectors in roughly logarithmic time, trading perfect accuracy for speed (*approximate* nearest neighbors).

Good at: meaning, paraphrase, cross-language matches. Bad at: exact rare tokens — "RRF" and "Reciprocal Rank Fusion" are close in meaning but the vector might not surface a literal product code.

### 3. Hybrid search + Reciprocal Rank Fusion (RRF)

Send **both** a text query and a vector query in the same request. The service runs both searches, then merges the two ranked lists:

```
RRF score(doc) = Σ over each result list   1 / (k + rank_in_that_list)      (k ≈ 60)
```

Only **ranks** are combined, not raw scores — because BM25 scores and cosine-similarity scores live on different, incomparable scales. A document that ranks well in *both* lists wins.

```ts
const results = await searchClient.search(queryText, {
  vectorSearchOptions: {
    queries: [{ kind: "vector", vector: queryEmbedding, fields: ["contentVector"], kNearestNeighborsCount: 50 }],
  },
  select: ["id", "title", "content"],
  top: 5,
});
```

Passing text **and** `vectorSearchOptions` together is what makes this a hybrid query.

### Bonus: the semantic ranker

An optional second stage that re-scores the top ~50 hybrid results using a cross-encoder model that reads the query and each passage *together* — more accurate than either BM25 or embedding distance alone, but too slow to run over an entire index, so it only re-ranks the first-stage shortlist.

## Why this matters for RAG

A RAG pipeline is, at its core:

1. Chunk your documents.
2. Embed each chunk and upload `{id, title, content, contentVector}` into the index.
3. At query time, embed the user's question, run a hybrid search, take the top N chunks.
4. Paste those chunks into the LLM's context with instructions to cite them.

Azure AI Search handles step 2 (storage) and step 3 (retrieval) in one managed service — you don't run your own vector database.

## Tiers, in short

| Tier | Notes |
|---|---|
| **Free** | $0, one per subscription, ~50 MB, good for learning |
| **Basic** | ~$75/month billed hourly, several GB, semantic ranker available |
| **Standard S1+** | Bigger, faster, more replicas/partitions, for production |

Delete the resource when you're done experimenting — paid tiers bill by the hour whether you use them or not.

## Check your understanding

1. Why does hybrid search usually beat pure vector search for RAG?
   <details><summary>Answer</summary>Vectors capture meaning but can miss exact rare terms (codes, names, acronyms) that keyword/BM25 search catches. RRF combines both ranked lists so documents strong in either (especially both) rise to the top.</details>
2. Why does RRF combine ranks instead of raw scores?
   <details><summary>Answer</summary>BM25 and cosine-similarity scores are on different, incomparable scales — ranks are the only thing that's directly comparable across the two result lists.</details>
3. What does the vector field's dimension have to match, and what happens if it doesn't?
   <details><summary>Answer</summary>It must match your embedding model's output size exactly (e.g. 1536). A mismatch causes indexing/query errors — you can't mix embeddings from different-dimension models in one vector field.</details>

## Next steps

- This repo's deep dive, with the real index schema and an ingestion pipeline you can run: `guides/07-azure-ai-search.md` (in the agentic-ai course)
- RAG fundamentals and chunking strategy: `guides/06-rag-and-embeddings.md` (in the agentic-ai course)
