# Azure OpenAI Setup Guide

> What Azure OpenAI is, how it works, and how to set it up for TrailForge, step by step in the **Azure portal** and with the **Azure CLI**, then connect the assistant and verify it.
> You'll end up with: one Azure OpenAI resource, two model deployments (`gpt-5-mini` for chat, `text-embedding-3-small` for RAG), keyless access from your laptop, and a working TrailForge chat.

## 1. What Azure OpenAI is

**Azure OpenAI** runs OpenAI's models (GPT, embeddings…) inside **your Azure subscription**. You call the same kind of API as OpenAI's own platform, but:

| | OpenAI platform | Azure OpenAI |
|---|---|---|
| Account | platform.openai.com account | An Azure **resource** in your subscription |
| Login | API key | API key **or Microsoft Entra ID** (no secrets) |
| Where data is processed | OpenAI | The Azure region / geography you choose |
| Models | Use any by name | You first **deploy** a model, then call your deployment |
| Limits | Per account | Per deployment (**TPM**: tokens per minute) |
| Networking, compliance | Basic | Private networking, Azure Policy, enterprise compliance |

You get it through **Azure AI Foundry** (the portal for AI models at https://ai.azure.com) or the classic Azure portal.

## 2. How it works: three words to learn

```
Azure subscription
└── Resource group  rg-trailforge
    └── Azure OpenAI resource  "trailforge-openai"            ← has an ENDPOINT + access control
        ├── Deployment "gpt-5-mini"           → model gpt-5-mini (version 2025-08-07), 50K TPM
        └── Deployment "text-embedding-3-small" → model text-embedding-3-small (v1), 50K TPM
```

| Word | Meaning | TrailForge |
|---|---|---|
| **Resource** | Your Azure OpenAI account: an endpoint like `https://trailforge-openai.openai.azure.com`, plus who's allowed to use it | One per environment |
| **Model** | What OpenAI built (`gpt-5-mini`, `text-embedding-3-small`) | Chosen per task |
| **Deployment** | *Your* named instance of a model inside the resource, with its own capacity. **In code, the "model" you pass is the deployment name.** | We name deployments after the model to keep it simple |

**A request, end to end in TrailForge:**
```
browser ─► gateway ─► assistant (OpenAI Agents SDK)
                         │ new OpenAI({ baseURL: <endpoint>/openai/v1/, apiKey: <key or Entra token> })
                         ▼
          POST https://trailforge-openai.openai.azure.com/openai/v1/responses
               body: { model: "gpt-5-mini", input: [...], tools: [...] }    ← "model" = deployment name
                         │  Azure checks: who are you (key/token)? allowed (role)? under quota (TPM)?
                         │  content filter on the prompt → model → content filter on the output
                         ▼
          streamed tokens ─► assistant ─► SSE ─► browser
```

- **The v1 endpoint** (`/openai/v1/`) is OpenAI-compatible, so the normal `openai` npm package and the Agents SDK work unchanged. Only the `baseURL` and credentials differ. See `services/assistant/src/openai.ts`.
- **Responses API:** the Agents SDK uses OpenAI's Responses API (`/responses`) by default. Embeddings use `/embeddings`.
- **Content filters** run on every request (hate, violence, self-harm, sexual, jailbreak) and can block a prompt or answer with a `content_filter` error.

## 3. Authentication: why we use Entra ID (no keys)

| | API key | **Microsoft Entra ID** (recommended) |
|---|---|---|
| What you send | `api-key` header (a long-lived secret) | A short-lived token (≈1 h) for `https://cognitiveservices.azure.com/.default` |
| Where it comes from | Copied from the portal | Your `az login` on a laptop; a **Managed Identity** in Azure |
| If it leaks | Works until someone rotates it | Expires; tied to one identity |
| Needs | Nothing else | A **role** on the resource: **Cognitive Services OpenAI User** |

TrailForge supports both: if `AZURE_OPENAI_API_KEY` is set it's used; otherwise `DefaultAzureCredential` picks up your `az login` (locally) or the Managed Identity (on Azure). **Same code, no secrets in `.env`.**

## 4. Before you start

- An Azure subscription where you can create resources (Owner, or Contributor + User Access Administrator, to assign roles).
- Azure CLI: `az login`, then `az account show -o table` to check the right subscription is selected (`az account set -s <id>` to switch).
- Pick a **region** that has both models. Check from the CLI:
  ```bash
  az cognitiveservices model list -l eastus2 \
    --query "[?model.name=='gpt-5-mini' || model.name=='text-embedding-3-small'].{model:model.name, version:model.version, sku:model.skus[0].name}" -o table
  ```
  If `gpt-5-mini` isn't listed, try `swedencentral`, `eastus` or `westus3`.
- Check quota (tokens per minute you're allowed) in that region: `az cognitiveservices usage list -l eastus2 -o table`.

## 5. Set up in the Azure portal (to see every piece)

> Portal labels change from time to time. If a button has moved, look for the same idea nearby.

1. **Create a resource group.** Portal → *Resource groups* → *Create* → name `rg-trailforge`, region **East US 2** → *Review + create*.
2. **Create the Azure OpenAI resource.** Portal → *Create a resource* → search **"Azure OpenAI"** → *Create*:
   - Resource group `rg-trailforge`, region East US 2
   - Name `trailforge-openai-<something unique>` (this becomes your endpoint's subdomain)
   - Pricing tier **Standard S0**
   - Network: *All networks* (fine for learning) → *Review + create*.
3. **Deploy the chat model.** Open the resource → *Go to Azure AI Foundry portal* (or https://ai.azure.com, select the resource) → *Deployments* → *Deploy model* → *Deploy base model* → **gpt-5-mini** → *Confirm*:
   - Deployment name **`gpt-5-mini`** (the name your code will use)
   - Deployment type **Global Standard** (pay per token, routed to available capacity)
   - Tokens per minute: start with **50K**
4. **Deploy the embedding model** the same way: **text-embedding-3-small**, deployment name **`text-embedding-3-small`**, Global Standard.
5. **Give yourself access (Entra ID).** Back on the resource in the Azure portal → *Access control (IAM)* → *Add* → *Add role assignment* → role **Cognitive Services OpenAI User** → *Members*: your user → *Review + assign*. Allow **up to ~5–10 minutes** before it takes effect.
6. **Copy the endpoint.** Resource → *Keys and Endpoint* (or *Resource Management → Keys and Endpoint*) → copy **Endpoint**, e.g. `https://trailforge-openai-xyz.openai.azure.com/`. You don't need the keys if you use Entra ID.
7. *(Optional)* **Try it in the playground:** Foundry → *Playgrounds → Chat* → pick `gpt-5-mini` → send a message.

## 6. The same setup with the Azure CLI

```bash
RG=rg-trailforge
LOC=eastus2
AOAI=trailforge-openai-$RANDOM            # must be globally unique

az group create -n $RG -l $LOC

# The resource (kind OpenAI, standard tier, custom subdomain = endpoint name)
az cognitiveservices account create -g $RG -n $AOAI -l $LOC \
  --kind OpenAI --sku S0 --custom-domain $AOAI --yes

# Chat deployment (capacity = thousands of tokens per minute)
az cognitiveservices account deployment create -g $RG -n $AOAI \
  --deployment-name gpt-5-mini --model-name gpt-5-mini --model-version 2025-08-07 \
  --model-format OpenAI --sku-name GlobalStandard --sku-capacity 50

# Embedding deployment
az cognitiveservices account deployment create -g $RG -n $AOAI \
  --deployment-name text-embedding-3-small --model-name text-embedding-3-small --model-version 1 \
  --model-format OpenAI --sku-name GlobalStandard --sku-capacity 50

# Let YOUR account call it with Entra ID (no keys)
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Cognitive Services OpenAI User" \
  --scope "$(az cognitiveservices account show -g $RG -n $AOAI --query id -o tsv)"

# The endpoint to put in .env
az cognitiveservices account show -g $RG -n $AOAI --query properties.endpoint -o tsv
az cognitiveservices account deployment list -g $RG -n $AOAI -o table
```

If the model version in the deployment command is rejected, use the version the `model list` command printed in §4. The agentic-ai course also has a Bicep template that creates all of this in one go (`infra/core.bicep`, run by `infra/provision-core.sh`).

## 7. Test it before touching the app

```bash
ENDPOINT=$(az cognitiveservices account show -g $RG -n $AOAI --query properties.endpoint -o tsv)
TOKEN=$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)

# Chat (the "model" is your DEPLOYMENT name)
curl -s "${ENDPOINT}openai/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d '{"model":"gpt-5-mini","messages":[{"role":"user","content":"Say hi in five words."}]}' | jq -r '.choices[0].message.content'

# Embeddings (should print 1536)
curl -s "${ENDPOINT}openai/v1/embeddings" \
  -H "Authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d '{"model":"text-embedding-3-small","input":"waterproof tent"}' | jq '.data[0].embedding | length'
```

A `401`/`403` right after assigning the role usually means "wait a few minutes" (role propagation).

## 8. Connect TrailForge

Edit the root `.env` (all backend services and scripts read it):

```bash
AZURE_OPENAI_ENDPOINT=https://trailforge-openai-xyz.openai.azure.com
AZURE_OPENAI_API_KEY=                                  # leave EMPTY → Entra ID via az login
AZURE_OPENAI_CHAT_DEPLOYMENT=gpt-5-mini
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
OPENAI_AGENTS_DISABLE_TRACING=true                     # don't send traces to platform.openai.com
```

Then restart the assistant (`npm run dev`, or `npm run dev:assistant`) and check:

1. **Status:** log in as admin → `GET /api/admin/assistant/status` shows `"model": true` and both MCP servers connected.
2. **Chat:** open http://localhost:5173, open the chat widget, ask *"What tents do you have under $400?"* You should see a `search_products` tool card, then a streamed answer.
3. **Logged-in flow:** ask *"Where is my order?"* as a guest → you get a **Log in** button; log in as `demo@trailforge.example` → ask again.

**What happens in the code:**
- `services/assistant/src/openai.ts` builds the client: `baseURL = <endpoint>/openai/v1/`; `apiKey` is either your key or a **token provider function** (`getBearerTokenProvider(new DefaultAzureCredential(), 'https://cognitiveservices.azure.com/.default')`) that the SDK calls before each request.
- `setDefaultOpenAIClient(client)` hands it to the Agents SDK; agents use `model: AZURE_OPENAI_CHAT_DEPLOYMENT`.
- `scripts/rag/src/ingest.ts` uses the embedding deployment to embed RAG chunks (see the Azure AI Search guide).

`gpt-5-mini` is a **reasoning model**: it doesn't accept `temperature`. Use reasoning effort settings instead if you tune it.

## 9. Quotas, cost and regions

- **TPM (tokens per minute)** per deployment; requests per minute follows from it. Going over gives **HTTP 429**. The `openai` SDK retries automatically with back-off. Raise capacity on the deployment (Foundry → Deployments → Edit) or request more quota.
- **Cost:** pay per token (input and output priced separately; embeddings are very cheap). Learning-scale use is typically a few dollars a month. Check current prices on the Azure OpenAI pricing page.
- **Deployment types:** *Global Standard* processes in any Azure region (cheapest, most capacity). *Data Zone* keeps processing in a geography (US/EU). *Standard* keeps it in the resource's region. Choose based on data-residency needs.
- **Clean up** when you stop practising: `az group delete -n rg-trailforge` (deletes everything in the group).

## 10. Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `401` / `PermissionDenied` with Entra ID | Role missing or not yet propagated | Assign **Cognitive Services OpenAI User** on the resource; wait 5–10 min; `az login` again |
| `401` with a key | Wrong or rotated key; or key auth disabled on the resource | Copy the key again, or use Entra ID |
| `404 DeploymentNotFound` | `AZURE_OPENAI_CHAT_DEPLOYMENT` doesn't match a deployment name | `az cognitiveservices account deployment list …` and fix `.env` |
| `404` on every call | Endpoint wrong (e.g. missing subdomain) | Use the exact endpoint from *Keys and Endpoint*; the code adds `/openai/v1/` |
| `429 Too Many Requests` | Over the deployment's TPM | Wait/retry, raise capacity, or use a smaller prompt |
| `400 … temperature` | Reasoning model parameter | Don't send `temperature` to `gpt-5-mini` |
| `content_filter` | Prompt or output blocked | Rephrase; check the content filter settings in Foundry |
| `DefaultAzureCredential failed to retrieve a token` | Not logged in | `az login` (and `az account set` to the right subscription) |
| Assistant says "not configured" | `AZURE_OPENAI_ENDPOINT` empty when the assistant started | Fill `.env`, restart the assistant |

## 11. Checklist

- [ ] Region chosen where both models are available; quota checked
- [ ] Resource group + Azure OpenAI resource created
- [ ] Deployments `gpt-5-mini` and `text-embedding-3-small` created
- [ ] **Cognitive Services OpenAI User** assigned to my account
- [ ] `curl` chat + embeddings tests pass with an Entra token
- [ ] `.env` filled (no key), assistant restarted, `/api/admin/assistant/status` shows `model: true`
- [ ] A product question streams an answer in the chat widget

Next: [Azure AI Search for RAG](azure-ai-search-rag-setup.md) · Related: [Deployment Plan](deployment-plan.md) (Managed Identity on Azure) · [MCP Guide](mcp-guide.md)
