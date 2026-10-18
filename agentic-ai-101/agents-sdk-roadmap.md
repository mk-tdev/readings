# OpenAI Agents SDK — Beginner to Mastery Roadmap

> A learning path through this repo's existing guides, ordered core → advanced. It doesn't introduce new material — it tells you what order to read things in and what to actually build at each stage. Tick items as you go; the study site saves your progress.

## How to use this

Each phase ends with a **milestone** — something you build or break on purpose, not just read. Reading without building gets you "I recognize these words," not mastery. If a phase's milestone feels too easy, you're ready for the next one; if it feels impossible, go back one phase.

## Phase 0 — Prerequisites (don't skip)

- [ ] Comfortable with modern async TypeScript (if not: `guides/01-node-ts-refresher.md` (in the agentic-ai course))
- [ ] Hand-wrote a tool-calling loop **without** the Agents SDK — `guides/02-llm-fundamentals.md` (in the agentic-ai course), `playground/src/03-tool-calling-by-hand.ts`

**Why this matters:** every SDK abstraction (`Agent`, `tool()`, the run loop) is a wrapper around the raw request/response cycle you build by hand here. Skip this and the SDK feels like magic; debugging it later means debugging magic.

## Phase 1 — Core

- [ ] The primitives: `Agent`, `run()`, the run loop — `guides/05-agents-sdk.md` (in the agentic-ai course), sections "The primitives" + "The run loop"
- [ ] The three kinds of tools (function, hosted, MCP) — same guide, "Three kinds of tools"
- [ ] Connecting to MCP servers — same guide, "Connecting to MCP servers"
- [ ] Streaming a run to a client — same guide, "Streaming to the browser"
- [ ] Sessions (memory across turns) — same guide, "Sessions (memory)"
- [ ] Guardrails — same guide, "Guardrails"
- [ ] Ran `npm run dev:all` and read `apps/chat/src/agent.ts` start to finish, matching every import to a concept above

**Milestone:** guide 05's exercises #4 (a "Quiz Master" agent with a handoff) and #5 (an agent used as a tool). If you can build both without copying the exercise text verbatim, you've got the core.

## Phase 2 — Intermediate: control and context

- [ ] Handoffs vs agents-as-tools — when to use which, and why `Agent.create({...})` matters for `finalOutput` typing — `guides/05-agents-sdk.md` (in the agentic-ai course), "Handoffs vs agents-as-tools"
- [ ] `RunContext<T>` — local context vs LLM-visible context, and why `isEnabled` isn't a security boundary — [`guides/101/context-management-101.md`](context-management-101.md)
- [ ] Tool approval: `needsApproval`, interruptions, resuming a paused run — [`guides/101/human-in-the-loop-101.md`](human-in-the-loop-101.md)
- [ ] MCP in depth: JSON-RPC wire format, transports, stateless server design, security — `guides/04-mcp.md` (in the agentic-ai course) + [`guides/101/mcp-101.md`](mcp-101.md)
- [ ] Provider plumbing: resource → deployment → model, API key vs Entra ID — `guides/03-azure-openai.md` (in the agentic-ai course) + [`guides/101/azure-openai-101.md`](azure-openai-101.md)

**Milestone:** implement guide 09's "Tool approval" exercise for real — make `delete_note` require confirmation, with an approve/deny UI in `apps/chat/public/app.js`. Then add a typed `RunContext` carrying the current user, and gate at least one tool's *actual* authorization check inside its `execute` (not just `isEnabled`).

## Phase 3 — Mastery: production-grade and specialized surfaces

- [ ] SDK-native testing — `ScriptedModel`, assertions, and why this is a different question from answer quality — [`guides/101/testing-evals-101.md`](testing-evals-101.md)
- [ ] Real evals — measuring whether answers got *better* after a change — `guides/09-hardening-next-steps.md` (in the agentic-ai course), "Evals: measure, don't guess"
- [ ] `SandboxAgent` — manifests, sessions, capabilities, providers, memory, for agents that need real shell/filesystem access — [`guides/101/sandbox-agents-101.md`](sandbox-agents-101.md)
- [ ] `RealtimeAgent` / `RealtimeSession` — speech-to-speech, transports, ephemeral tokens (optional — only if voice is relevant to what you're building) — [`guides/101/voice-agents-101.md`](voice-agents-101.md)
- [ ] Tracing and hardening — prompt injection, SSRF, least privilege, rate limits, OpenTelemetry — `guides/09-hardening-next-steps.md` (in the agentic-ai course)
- [ ] RAG as a retrieval surface over MCP — the dominant real-world pairing with agents — `guides/06-rag-and-embeddings.md` (in the agentic-ai course) + `guides/07-azure-ai-search.md` (in the agentic-ai course)

**Capstone milestone:** design and build a 4th MCP server from scratch (guide 04's exercise #5 — `github`, `azure-costs`, or `flashcards`). Wire it so that:
1. at least one tool requires approval (`needsApproval`),
2. authorization is enforced inside `execute` using a typed `RunContext`, not just `isEnabled`,
3. you have a small `ScriptedModel`-based test suite covering the happy path and one failure mode,
4. you have a tiny eval set (3–5 fixed questions) you can re-run after any prompt change.

If you can do all four without re-reading the guides, you've covered the SDK end to end — including the parts most tutorials skip (approval, context, testing).

## What "mastery" actually looks like

Not "I've read every page" — rather:

- You can explain *why* the SDK separates tools/resources/prompts in MCP, or local vs LLM-visible context, to someone else without looking it up.
- You can extend `apps/chat/src/agent.ts` with a new capability (a tool, a handoff, an approval gate) by reasoning from the primitives, not by copy-pasting the closest existing exercise.
- When something breaks, you can read the SDK's error (a 404 DeploymentNotFound, an `UnexpectedModelCallError`, a `content_filter` block) and know which layer it came from and why.

## Next steps once you're through this

- Guide 09's "Stretch" / "Next projects" section has ideas beyond this repo's scope.
- Re-read [`guides/101/mcp-101.md`](mcp-101.md)'s comparison with [`guides/101/grpc-101.md`](grpc-101.md) — once the Agents SDK feels natural, protocol-level comparisons like this are a good way to deepen "why this design, not that one" intuition.
