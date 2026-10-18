# Testing & Evals 101 — OpenAI Agents SDK

> A quick, standalone primer. This repo's only quality check today is the hand-rolled eval script sketched in `guides/09-hardening-next-steps.md` (in the agentic-ai course) ("Evals: measure, don't guess") — there's no test suite around `apps/chat/src/agent.ts` at all. This guide covers the SDK's own testing tools, and draws a hard line between two things people conflate.

## Two different questions, two different tools

| | **Testing** (this guide) | **Evals** (guide 09) |
|---|---|---|
| Question it answers | "Does my code call the right tools, handle errors, and wire things together correctly?" | "Is the model's output actually *good* — correct, on-topic, well-cited?" |
| How | Deterministic, in-memory test doubles — no real model call | Run real prompts against a real model, score the answers |
| Speed / cost | Fast, free, runs in CI | Slow(er), costs tokens |
| What it can't tell you | Whether the model is *good at the task* | Whether your code's plumbing is correct |

The Agents SDK's testing utilities are squarely the left column. If you've been thinking "I'll just write unit tests to check my agent gives good answers" — that's actually an eval, not a test, and the two need different tools.

## Setup: make sure tests don't call real tracing

Tracing is separate from the test doubles below and can still try to export spans during a test run. Disable it with any one of:

```ts
new Runner({ tracingDisabled: true });
// or
process.env.NODE_ENV = "test";
// or
process.env.OPENAI_AGENTS_DISABLE_TRACING = "1";
// or
import { setTracingDisabled } from "@openai/agents";
setTracingDisabled(true);
```

Import the test doubles from `@openai/agents/testing` (agents + sandbox) and `@openai/agents/realtime/testing` (voice).

## Scripting a fake model: `ScriptedModel`

Instead of hitting a real LLM, you script an ordered list of steps — one per expected model call:

```ts
import { Agent, run } from "@openai/agents";
import { ScriptedModel, assistantMessage, functionCall } from "@openai/agents/testing";

const model = new ScriptedModel([
  functionCall("get_weather", { city: "Chennai" }, { callId: "call_1" }),
  assistantMessage("It's 32°C and humid in Chennai."),
]);

const agent = new Agent({ name: "Weather bot", model, tools: [getWeatherTool] });
const result = await run(agent, "What's the weather in Chennai?");

model.assertComplete(); // fails if any scripted step was left unused
```

| Step builder | Does |
|---|---|
| `assistantMessage(text)` | Model returns a fixed final answer |
| `functionCall(name, args, { callId })` | Model calls a tool — the **real** tool pipeline still runs (validation, hooks, guardrails), only the *model's decision* is scripted |
| `modelResponder(fn)` | Pick a response based on the actual request — use only when behavior genuinely depends on it |
| `modelError(error, retryAdvice?)` | Fail one call (a retry consumes the *next* scripted step) |
| `modelStream(events)` | Script an exact streamed sequence |

The key design choice: **tools are never bypassed.** Scripting `functionCall` only fakes the model's *decision* to call a tool — your actual `execute` function, its zod validation, and any guardrails still run for real. That's what makes this a test of your *wiring*, not a mock of your own logic.

## Assertions

```ts
model.calls;              // every call made, each with { index, streamed, request }
model.firstCall;
model.lastCall;
model.remainingSteps;     // steps not yet consumed
model.assertComplete();   // call this at the end of every test
```

`request` on a call gives you `request.input`, `request.tools`, `request.modelSettings` — so you can assert, for example, "the model was offered exactly these three tools" or "the conversation history sent on turn 2 included the tool result from turn 1."

If something goes wrong, the SDK throws specific error types (`UnexpectedModelCallError`, `UnconsumedModelStepsError`, `InvalidScriptedModelStepError`, `ScriptedModelRequestAbortedError`), each with structured fields like `callIndex` and `remainingSteps`. Assert on those fields directly rather than string-matching the error message.

## Scripting a sandbox session

If you're testing a [`SandboxAgent`](sandbox-agents-101.md), you don't need a real sandbox to spin up:

```ts
import { scriptedSandboxSession } from "@openai/agents/testing";

const session = scriptedSandboxSession([
  { method: "execCommand", match: (cmd) => cmd.includes("npm test"), result: { stdout: "5 passed", exitCode: 0 } },
]);

await run(agent, "Run the tests.", { sandbox: { session } });
session.assertComplete();
```

Only methods you've scripted are exposed — this preserves capability detection (the agent still sees a realistic, if minimal, sandbox surface) while keeping the test deterministic and free.

## Scripting a Realtime (voice) session

For [voice agents](voice-agents-101.md), `ScriptedRealtimeTransport` plugs into a **real** `RealtimeSession` — tool calls still go through the real `RealtimeAgent` tools, same principle as `ScriptedModel`:

```ts
import { runScenario, expectCall, emit } from "@openai/agents/realtime/testing";

await runScenario({
  scenario: [
    expectCall("connect"),
    emit("function_call", { name: "get_weather", args: { city: "Chennai" } }),
    expectCall("sendFunctionCallOutput"),
  ],
  exercise: async (transport) => {
    const session = new RealtimeSession(agent, { transport });
    await session.connect({ apiKey: "ek_test" });
  },
});
```

`expectCall` asserts outbound calls happen in order (`connect`, `sendMessage`, `interrupt`, `close`, …); `emit` delivers inbound events (`function_call`, `audio`, `audio_interrupted`, …); `failNextCall` injects a failure into the next matching call; `disconnect` simulates the remote end hanging up. Finish with `transport.assertComplete()` and `transport.assertClosed()`.

## What this testing layer deliberately does *not* cover

Straight from the SDK's own scope statement — don't reach for these test doubles to check:

- **Model or tool-selection quality** — "did the model pick a good tool / give a good answer" is an eval question (see guide 09), not a test question.
- **Provider wire format** — exact HTTP/WebSocket payloads; use the real adapter against a mocked network if you need that.
- **Sandbox provider isolation** — whether Docker/hosted isolation actually holds; that's an integration test against the real provider.
- **Raw Realtime server frames or audio** — the scripted transport works at the event level, not raw bytes.

## Common mistakes

- **Forgetting `model.assertComplete()`** — without it, a test can silently pass while leaving scripted steps (and the behavior they were meant to verify) unexercised.
- **Treating a passing test suite as proof the agent "works well."** It proves your code's plumbing is correct for the scenarios you scripted — it says nothing about whether the model's actual judgment is good. That's what guide 09's eval set is for.
- **Not disabling tracing in CI**, causing slow or flaky exports during test runs.
- **Trying to mock tool `execute` functions directly** instead of using `functionCall()` — you'd lose coverage of your own validation/guardrail wiring, which is the main thing worth testing.

## Check your understanding

1. If `ScriptedModel` is told to make a `functionCall`, does your tool's real `execute` function run, or is that mocked too?
   <details><summary>Answer</summary>It runs for real — only the model's decision to call that tool is scripted. Validation, hooks, and guardrails all execute normally, which is what makes this a test of your integration code rather than a mock of your own logic.</details>
2. Your CI suite is green. Does that tell you the agent gives good answers to real user questions?
   <details><summary>Answer</summary>No — it tells you the code paths you scripted behave as wired (right tools called, right data flows through). Answer quality is an evals question, answered by running real prompts against a real model and scoring the results, as in guide 09's eval script.</details>
3. Why does the SDK recommend asserting on structured fields like `callIndex` on a thrown error, rather than matching the error's message string?
   <details><summary>Answer</summary>Structured fields are stable and precise; message text can change between SDK versions and is easy to match too loosely or too strictly. Asserting on `callIndex`/`remainingSteps` directly ties your test to the actual failure, not to incidental wording.</details>

## Next steps

- This repo's answer-quality eval script: `guides/09-hardening-next-steps.md` (in the agentic-ai course), "Evals: measure, don't guess".
- Testing a paused, approval-gated tool call combines naturally with `functionCall()` scripting: [`human-in-the-loop-101.md`](human-in-the-loop-101.md).
- Official docs: openai.github.io/openai-agents-js/guides/testing
