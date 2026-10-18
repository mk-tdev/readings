# Human-in-the-Loop & Tool Approval 101 — OpenAI Agents SDK

> A quick, standalone primer. This repo describes this exact feature as a *suggested exercise* for `delete_note` in `guides/09-hardening-next-steps.md` (in the agentic-ai course) but doesn't implement it — this guide fills in the "how" so you can actually build it.

## The problem

An agent decides on its own which tools to call. That's fine for `search_notes`, but you probably don't want a model — possibly nudged by a prompt-injected web page — to silently call `delete_note` or `charge_card`. You want a human to see "the agent wants to do X" and click approve or deny *before* it happens.

The Agents SDK builds this in: mark a tool as needing approval, and the SDK **pauses the run** instead of executing it, hands you a structured description of what's pending, and lets you **resume later** — even after a server restart — once a decision is made.

## Step 1 — mark a tool as needing approval

```ts
import { tool } from "@openai/agents";
import { z } from "zod";

const deleteNote = tool({
  name: "delete_note",
  description: "Delete a note by id. Only call this when the user explicitly asks to delete.",
  parameters: z.object({ id: z.string() }),
  needsApproval: true, // always require approval
  execute: async ({ id }) => {
    // this code only runs after an explicit approval
    return `Deleted note ${id}`;
  },
});
```

`needsApproval` can also be an **async function** that decides based on context and the (already-parsed) arguments — e.g. only require approval above a dollar amount:

```ts
needsApproval: async (runContext, { amount }) => amount > 100,
```

One important edge case: the approval function only runs once the model's arguments have successfully parsed into an object. If the model sends malformed JSON, the SDK **fails closed** — it still requests approval, skips your callback, and the tool never executes.

## Step 2 — the run pauses, you get `interruptions`

When the model calls a tool that needs approval and no decision exists yet:

1. The tool does **not** execute.
2. The run records a `RunToolApprovalItem` describing the pending call.
3. At the end of the turn, the run stops and hands back `result.interruptions` — an array of these pending items (there can be more than one, e.g. the model requested two approval-gated tools in parallel).

```ts
const result = await run(agent, "Delete my note about the meeting");

for (const interruption of result.interruptions) {
  console.log(`Approve ${interruption.rawItem.name}(${JSON.stringify(interruption.rawItem.arguments)})?`);
}
```

## Step 3 — resolve each interruption

```ts
// approve this one call only
result.state.approve(interruption);

// reject it, with a message the model will see as the tool's output
result.state.reject(interruption, { message: "User declined this action." });

// or make the decision sticky for every future call to this tool, this run
result.state.approve(interruption, { alwaysApprove: true });
result.state.reject(interruption, { alwaysReject: true });
```

An exact per-call decision always overrides a sticky `alwaysApprove`/`alwaysReject` default set earlier.

## Step 4 — resume the run

```ts
const resumed = await run(agent, result.state); // same top-level `agent`
```

You don't have to resolve every pending item before resuming — anything left unresolved will simply cause the run to pause again with those items still in `interruptions`.

## The full loop, start to finish

```ts
let result = await run(agent, userMessage);

while (result.interruptions.length > 0) {
  for (const interruption of result.interruptions) {
    const decision = await askHumanToApprove(interruption); // your UI
    if (decision === "approve") result.state.approve(interruption);
    else result.state.reject(interruption);
  }
  result = await run(agent, result.state);
}

console.log(result.finalOutput);
```

This mirrors the SDK's own CLI example: a `get_weather` tool that requires approval only for San Francisco, looping until there are no more interruptions, with the state saved to disk between prompts.

## Pausing across requests: serialize `RunState`

The example above assumes one long-lived process. In a real web app (like this repo's `apps/chat`), the approval UI round-trip is a *separate HTTP request* — the run needs to survive in between.

```ts
// before returning control to the browser
const saved = result.state.toString(); // or JSON.stringify(result.state)
await saveToDatabase(conversationId, saved);

// later, when the user clicks "approve" in the UI
const state = RunState.fromString(agent, await loadFromDatabase(conversationId));
state.approve(interruption);
const resumed = await run(agent, state);
```

A few things that matter here:

- `agent` passed to `fromString`/`run` must be **the same root agent graph** you started with — stable agent names let the SDK match things back up even if several agents share structure.
- The serialized state includes your `runContext.context` and other runtime metadata — see [`context-management-101.md`](context-management-101.md) for why you shouldn't put secrets there.
- Tracing API keys are **excluded** from serialization by default; only include them (`toString({ includeTracingApiKey: true })`) if you specifically need to.
- If you're using the streaming API instead, wait for the `stream.completed` event, read `stream.interruptions`, resolve them the same way, then call `run(agent, state, { stream: true })` to resume.
- If you passed a `session` to the original run, pass the **same session** when resuming.

## Security: this is a trust boundary, treat it like one

`RunState.fromString()` **restores state without authenticating it** — it will happily deserialize anything you hand it. For a multi-user app, that's dangerous if you're not careful. If you build an approval UI that spans a network boundary (a web form, a Slack approval button):

1. **Keep the full snapshot server-side.** Send the reviewer only a human-readable summary and an opaque decision id — never the raw serialized state.
2. **Authenticate the reviewer** through your normal auth middleware, never by trusting a field in the request body.
3. **Authorize** that this specific reviewer may approve this specific run/tool call.
4. **Validate against server-stored pending requests** — never accept a tool call, its arguments, or a state blob supplied directly by the client.
5. **Consume the pending request atomically** (check-and-mark-used in one step) before deserializing and resuming, so the same approval can't be replayed twice.

Note that "consumed once" prevents a *replayed approval*, but doesn't by itself guarantee the underlying tool only has a side effect once (e.g. network retries) — reconcile that separately if the action isn't naturally idempotent.

## Other approval surfaces (good to know, used less often)

- **Hosted tools** like `shellTool()` and `applyPatchTool()`, and hosted MCP tools, take an `onApproval` callback that decides *in code* without pausing the whole run — useful for policy you can express as a function rather than a human click.
- **Computer-use tools** can batch several actions in one `computer_call`; approval is evaluated per action, and `onSafetyCheck` handles a related-but-separate pending-safety-check flow.

## Common mistakes

- **Forgetting that malformed arguments still trigger approval** — your `needsApproval` function won't even run in that case; the SDK fails closed and pauses anyway.
- **Resuming with the wrong agent object** — `RunState.fromString`/`run()` need the same root agent graph that produced the state, not just "an agent with the same name."
- **Treating client-submitted state as trustworthy** — always re-validate server-side before resuming a run that crosses a network/trust boundary.
- **Putting secrets in `runContext.context`** when you know the run might be serialized for an approval pause.

## Check your understanding

1. What happens if the model's tool call arguments fail to parse as valid JSON for an approval-gated tool?
   <details><summary>Answer</summary>The SDK fails closed: it still requests approval and records an interruption, but your <code>needsApproval</code> callback is skipped and the tool does not execute, since there's no valid parsed arguments to evaluate.</details>
2. Why must you pass the same root `agent` object when calling <code>RunState.fromString</code> or resuming a run?
   <details><summary>Answer</summary>The serialized state encodes positions within a specific agent graph; stable agent identities let the SDK match the restored state back onto the rebuilt graph correctly, even across process restarts.</details>
3. In a multi-user web app, why shouldn't the browser hold the full serialized `RunState`?
   <details><summary>Answer</summary><code>RunState.fromString()</code> deserializes without authenticating the content — if a client could supply or tamper with the state directly, they could potentially forge approvals or resume someone else's run. Keep the snapshot server-side and send the client only a summary plus an opaque decision id.</details>

## Next steps

- `RunContext.approveTool`/`.rejectTool` and what else lives on the context object: [`context-management-101.md`](context-management-101.md)
- This repo's suggested exercise to actually wire this into `delete_note`: `guides/09-hardening-next-steps.md` (in the agentic-ai course)
- Official docs: openai.github.io/openai-agents-js/guides/human-in-the-loop
