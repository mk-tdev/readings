# Context Management 101 — OpenAI Agents SDK

> A quick, standalone primer on the Agents SDK's `RunContext`. This repo's chat app (`apps/chat/src/agent.ts`) doesn't currently use typed run context — tools there are stateless — so treat this as the natural next step once you've worked through `guides/05-agents-sdk.md` (in the agentic-ai course).

## Two things people call "context" — don't mix them up

The word "context" means two different things in the Agents SDK, and conflating them is the single most common source of confusion:

| | **Local context** | **LLM-visible context** |
|---|---|---|
| What it is | App-level data/dependencies your *code* can read | What the *model* actually sees when it generates a response |
| Lives where | A plain object you create (`RunContext<T>`) | The conversation history sent in the request |
| Sent to the model? | **Never** | Yes — this is its whole job |
| Typical use | user id, a logger, a DB client, feature flags | instructions, prior turns, tool results |

## Local context: `RunContext<T>`

You create an object to hold whatever your tools or hooks need, and pass it into the run:

```ts
import { Agent, run, tool } from "@openai/agents";
import { z } from "zod";

interface UserInfo {
  name: string;
  uid: number;
}

const fetchUserAge = tool({
  name: "fetch_user_age",
  description: "Return the current user's age.",
  parameters: z.object({}),
  execute: async (_args, runContext) => {
    // runContext.context is YOUR typed object — never sent to the model
    return `${runContext.context.name} is 47 years old.`;
  },
});

const agent = new Agent<UserInfo>({
  name: "Assistant",
  tools: [fetchUserAge],
});

const result = await run(agent, "What is the age of the user?", {
  context: { name: "Ada", uid: 42 },
});
```

Rules worth internalizing:

- **One context type per run.** Every agent, tool, and hook involved in a single `run()` must agree on the same `T` in `RunContext<T>`.
- **It's for dependencies, not conversation.** Think loggers, data fetchers, user ids, helper functions — not "what the user said five turns ago." That's conversation history (`result.history`, a `session`, `conversationId`, or `previousResponseId`), which is a completely separate mechanism.
- **Nested runs share it.** If an agent is used as a tool via `agent.asTool()`, the nested run shares the same app context, approval state, and usage tracking as the outer run — it does **not** get an isolated copy by default.

### What else lives on `runContext`

Besides your own `context`, the SDK attaches runtime metadata to the same object:

| Property | What it is |
|---|---|
| `runContext.context` | **Your** app-defined state — the only field you control |
| `runContext.usage` | Aggregated token/request usage for the run so far |
| `runContext.toolInput` | Structured input, when running inside `agent.asTool()` |
| `runContext.approveTool(...)` / `.rejectTool(...)` | Programmatically resolve a pending tool approval (see the human-in-the-loop guide) |

> **Watch out:** if you serialize `RunState` for a human-in-the-loop flow (pausing a run for approval), *all* of this — including your `context` object — gets written out. Don't put secrets in `runContext.context` if the state might be persisted or sent over the wire.

## `isEnabled` callbacks are visibility, not security

Function tools, handoffs, and MCP's `toolFilter` all accept an `isEnabled` predicate that receives the current `RunContext` and decides whether that capability is even shown to the model this turn:

```ts
const deleteNote = tool({
  name: "delete_note",
  // ...
  isEnabled: ({ runContext }) => runContext.context.role === "admin",
});
```

This is useful for cutting down the tool list per-request — but it runs **before** the model generates arguments, so it cannot validate *what* the model asks for, only *whether the tool is listed at all*. Two consequences:

- **Authorize inside `execute`, not just in `isEnabled`.** If "can this user delete notes" matters, check it again inside the tool's handler (or use an input guardrail + approval), because a model could still be coerced into attempting a call if your `isEnabled` logic has a gap.
- **For handoffs with a typed `inputType`**, check the parsed input at the very start of `onHandoff` — before any side effects — and throw if it fails authorization. Tool input guardrails do not run for handoffs.

## The LLM-visible side: four ways to get information to the model

The model only ever sees conversation history. To add more:

1. **Agent `instructions`** — static string, or a function that receives the context and returns a string (useful for "personalize the system prompt from `runContext.context`" without exposing the raw object).
2. **`input` to `run()`** — similar to instructions but lower in the chain-of-command ordering.
3. **Function tools** — let the model *ask* for information on demand instead of pre-loading everything.
4. **Retrieval / search tools** — ground answers in files, a database, or the web (this is exactly what `search_knowledge` does in this repo's `mcp-servers/knowledge`).

## Common mistakes

- **Putting conversation state in `RunContext`.** It's for dependencies/metadata, not "what was said" — use sessions/history for that (see `guides/05-agents-sdk.md` (in the agentic-ai course), "Sessions (memory)").
- **Treating `isEnabled` as an authorization boundary.** It filters what the model can see, not what a determined/injected prompt can attempt — the real check belongs inside the tool's `execute`.
- **Serializing secrets.** Anything in `runContext.context` can end up in a persisted `RunState` if you build an approval flow — keep tokens/credentials out of it, or redact before persisting.
- **Assuming nested `agent.asTool()` runs get isolated state.** They share the parent's app context and approval/usage tracking.

## Check your understanding

1. If a tool needs the current user's id, should that id live in `RunContext` or in the conversation history?
   <details><summary>Answer</summary><code>RunContext</code> — it's app-level data your code needs, not something the model said or should see directly.</details>
2. Why can't an <code>isEnabled</code> predicate be your only authorization check for a destructive tool?
   <details><summary>Answer</summary>It only decides whether the tool is listed to the model before arguments are generated — it can't inspect or validate the arguments the model eventually produces. Re-check authorization inside <code>execute</code>, or use an input guardrail / approval step.</details>
3. What happens to your <code>runContext.context</code> object if you serialize <code>RunState</code> for a human-in-the-loop pause?
   <details><summary>Answer</summary>It gets written out as part of the serialized state, so secrets placed there would be persisted/transmitted too — keep sensitive values out of it.</details>

## Next steps

- Pausing a run for approval also touches `RunContext` (`approveTool`/`rejectTool`) — see [`human-in-the-loop-101.md`](human-in-the-loop-101.md).
- This repo's session/memory coverage: `guides/05-agents-sdk.md` (in the agentic-ai course) — "Sessions (memory)".
- Official docs: openai.github.io/openai-agents-js/guides/context
