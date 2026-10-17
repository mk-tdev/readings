# Azure OpenAI 101 — from zero

> A quick, standalone primer. For the deep dive tied to this repo's actual code (the provider-switching function, Entra ID walkthrough, quota/content-filter details, hands-on exercises), see `guides/03-azure-openai.md` (in the agentic-ai course).

## What it is

**Azure OpenAI** gives you the same OpenAI model family (GPT, embeddings, etc.) running **inside your own Azure subscription**, instead of calling `api.openai.com` directly. Same models, same general API shape — different plumbing around it:

| | OpenAI | Azure OpenAI |
|---|---|---|
| Where it runs | OpenAI's infrastructure | Your Azure subscription / network |
| Auth | API key | API key **or** Microsoft Entra ID (RBAC) |
| Billing | OpenAI account | Azure subscription / enterprise agreement |
| Networking | Public internet | Can sit behind a VNet, private endpoints |
| Compliance | OpenAI's terms | Azure's regional data residency, enterprise SLAs |

Most companies that have already standardized on Azure (for compliance, networking, or procurement reasons) use Azure OpenAI for exactly that reason — not because the models differ.

## The vocabulary: resource → deployment → model

```text
Azure subscription
└── Resource group
    └── Azure OpenAI resource   (e.g. "my-openai-prod")
        │   endpoint: https://my-openai-prod.openai.azure.com
        ├── Deployment "gpt-5-mini"   ──► model gpt-5-mini, with its own quota
        └── Deployment "embeddings"   ──► model text-embedding-3-small
```

- **Resource** — the Azure object you create. Has an endpoint URL, a region, keys, and RBAC role assignments.
- **Model** — what OpenAI trained (`gpt-5-mini`, `text-embedding-3-small`, …).
- **Deployment** — *your* named instance of a model inside the resource, with its own capacity (quota) and content-filter policy. **On Azure, the `model` parameter in your API call is actually the deployment name** — this trips up almost everyone the first time. If you deploy `gpt-5-mini` under the name `my-chat`, you call it with `model: "my-chat"`.

## The endpoint

Azure OpenAI exposes an **OpenAI-compatible v1 API**:

```text
https://<resource>.openai.azure.com/openai/v1/
```

Because it's compatible, the official `openai` npm/pip package works unchanged — you only swap the `baseURL` and credentials:

```ts
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "https://my-openai-prod.openai.azure.com/openai/v1/",
  apiKey: process.env.AZURE_OPENAI_API_KEY,
});

const res = await client.chat.completions.create({
  model: "gpt-5-mini", // the DEPLOYMENT name, not necessarily the model name
  messages: [{ role: "user", content: "Say hi in one word." }],
});
```

## Authentication: keys vs Microsoft Entra ID

| | API key | Entra ID (recommended for production) |
|---|---|---|
| How | static secret in a header | short-lived OAuth token for scope `https://cognitiveservices.azure.com/.default` |
| Risk if leaked | full access until manually rotated | tokens expire (~1h); tied to an identity |
| Granularity | all-or-nothing | **RBAC roles** per user/app, auditable |

The `@azure/identity` package's `DefaultAzureCredential` tries a chain of sources and uses whichever works — your `az login` session on a laptop, a managed identity in the cloud — so the *same code* authenticates correctly in both places with zero secrets committed anywhere:

```ts
import { DefaultAzureCredential, getBearerTokenProvider } from "@azure/identity";

const tokenProvider = getBearerTokenProvider(
  new DefaultAzureCredential(),
  "https://cognitiveservices.azure.com/.default",
);

const client = new OpenAI({
  baseURL: "https://my-openai-prod.openai.azure.com/openai/v1/",
  apiKey: tokenProvider, // a function the SDK calls before each request
});
```

**The RBAC role you need to actually call models is "Cognitive Services OpenAI User."** *Contributor* can manage the resource (create/delete deployments) but **cannot** call the models — a very common first-day gotcha.

## Quotas and rate limits

- Each deployment has **capacity** measured in **TPM** (tokens per minute), which implies a request-per-minute limit too.
- Deployment types: **Standard** (fixed region), **GlobalStandard** (Azure routes to whichever region has capacity — best availability), **DataZone** (stays within a geography like the US/EU), **Provisioned** (reserved throughput).
- Going over your limit returns **HTTP 429** with a `retry-after` header; most SDKs retry automatically a couple of times.

## Content filters

Every deployment applies a content-filtering policy (hate, violence, self-harm, jailbreak attempts, etc.) to both prompts and completions:

- A blocked **prompt** → `400` with code `content_filter`.
- A blocked **completion** → cut short with `finish_reason: "content_filter"`.

You can view/customize the policy in Azure AI Foundry; the defaults are reasonable for most apps.

## Common errors, decoded

| Error | Usual cause | Fix |
|---|---|---|
| **401** Unauthorized | no valid credential | check your API key is for *this* resource, or run `az login` |
| **403** PermissionDenied | authenticated, but missing role | assign **Cognitive Services OpenAI User**; wait a few minutes for it to propagate |
| **404** DeploymentNotFound | wrong name, or still creating | list deployments; remember it's the *deployment* name, not the model name |
| **429** Too Many Requests | over TPM/RPM | back off and retry, or raise deployment capacity |
| **400** content_filter | blocked content | rephrase, or adjust the filter policy |

## Check your understanding

1. In an Azure OpenAI API call, what goes in the `model` field?
   <details><summary>Answer</summary>The deployment name you created in the resource — which may or may not match the underlying model's name.</details>
2. Why does <code>Contributor</code> access not let you call a model via Entra ID?
   <details><summary>Answer</summary>Contributor manages the Azure resource itself (create/delete/configure), but calling the inference API requires the separate data-plane role "Cognitive Services OpenAI User".</details>
3. What's the practical benefit of <code>DefaultAzureCredential</code> over hardcoding a key?
   <details><summary>Answer</summary>The same code works unchanged across environments (your laptop via `az login`, a container via managed identity) with no secret ever stored in config, and tokens expire automatically instead of living forever.</details>

## Next steps

- This repo's deep dive, with a real provider-switching function and hands-on exercises: `guides/03-azure-openai.md` (in the agentic-ai course)
- Azure AI Foundry portal — where you create resources, deployments, and view quotas/monitoring.
