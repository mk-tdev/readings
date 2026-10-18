# Sandbox Agents 101 — OpenAI Agents SDK

> A quick, standalone primer. This repo's agent never runs arbitrary shell commands or edits a filesystem — its tools are narrow, purpose-built functions (`create_note`, `convert_units`, `search_knowledge`). Sandbox agents are the SDK's answer to a different, riskier job: letting a model actually *operate a computer*.

## The problem it solves

A tool like `convert_units` does exactly one thing and nothing else — there's no way to misuse it into running `rm -rf /`. But some agents genuinely need an open-ended environment: a coding agent that edits files and runs tests, a data-analysis agent that writes and executes scripts. Giving a model raw shell access is dangerous without **isolation** (what can it reach?) and **structure** (what's already in its workspace, and what happens to its work afterward?).

**Sandbox agents** extend the normal `Agent` with exactly that: a declared starting workspace, a set of scoped, sandbox-aware built-in tools (shell, filesystem), and a pluggable *provider* that actually isolates execution — anything from "none, it's your own machine" to a container to a fully hosted environment.

## `SandboxAgent` — still a normal agent

```ts
import { SandboxAgent, Manifest, file, gitRepo } from "@openai/agents";

const agent = new SandboxAgent({
  name: "Coding assistant",
  instructions: "Fix the failing test, then explain the change.",
  defaultManifest: new Manifest({
    root: "/workspace",
    entries: {
      "task.md": file({ content: "Fix the failing test." }),
      repo: gitRepo({ repo: "your-org/your-repo", ref: "main" }),
    },
    environment: { NODE_ENV: "test" },
  }),
});
```

It keeps everything you already know from `Agent` — `instructions`, `tools`, `handoffs`, MCP servers, guardrails, lifecycle hooks, and the same `run()`/`Runner` API. On top of that it adds sandbox-specific defaults: a `defaultManifest`, optional `baseInstructions`, `runAs` (the user identity for model-facing shell/file operations), and `capabilities`.

## Two concepts: Manifest vs. sandbox session

These sound similar and are easy to mix up:

| | **Manifest** | **Sandbox session** |
|---|---|---|
| What it is | A *declaration* of what a fresh workspace starts with — files, repos, mounts, env vars, path grants | The *live* execution environment where commands actually run and files actually change |
| When it matters | Only at session creation | For the whole run, and potentially across multiple runs |

A manifest is a recipe; a session is the kitchen actually cooking it.

## Lifecycle: who owns the session?

**SDK-owned** — simplest option, one session per run:

```ts
import { run } from "@openai/agents";
import { UnixLocalSandboxClient } from "@openai/agents";

const result = await run(agent, "Inspect the workspace.", {
  sandbox: { client: new UnixLocalSandboxClient() },
});
```

**Developer-owned** — reuse one session across multiple `run()` calls (e.g. a multi-step task), and close it yourself:

```ts
const client = new UnixLocalSandboxClient();
const session = await client.create({ manifest });
try {
  await run(agent, "First task.", { sandbox: { session } });
  await run(agent, "Follow-up task.", { sandbox: { session } }); // same workspace, same files
} finally {
  await session.close?.();
}
```

You can also **resume** a previous session via runner-managed `RunState`, an explicit `sandbox.sessionState`, or a `sandbox.snapshot` fed into a fresh session — useful for picking up long-running work across process restarts, the same way [human-in-the-loop](human-in-the-loop-101.md) resumes a paused run from `RunState`.

## Capabilities: the built-in sandbox tools

Instead of you hand-writing a "run shell command" tool (and getting the security boundary subtly wrong), the SDK ships ready-made **capabilities** that attach a matched set of tools to the live session:

| Capability | Adds | Notes |
|---|---|---|
| `shell()` | `exec_command` (+ `write_stdin` if the provider supports a PTY) | Runs commands as the `runAs` user |
| `filesystem()` | `apply_patch`, `view_image` | Patch-based file edits; images up to 10 MB by file-signature detection |
| `skills()` | — | Reusable task playbooks |
| `memory()` | — | Learn from earlier runs (needs `shell()`; live updates need `filesystem()` — see below) |
| `compaction()` | — | Keeps long sandbox transcripts manageable |

The default set is `filesystem()` + `shell()` + `compaction()`. **Passing your own `capabilities` array replaces the default entirely** — if you still want shell access, list it explicitly.

## Sandbox providers: where isolation actually comes from

The capability tools are the same regardless of provider; what changes is *how real the isolation is*:

| Client | Isolation | Use for |
|---|---|---|
| `UnixLocalSandboxClient` | **None** — runs directly on your machine (macOS/Linux) | Trusted local development only |
| `DockerSandboxClient` | Container boundary, with host↔sandbox path grants | Local testing of less-trusted commands |
| Hosted / provider-managed clients | Fully isolated, provider-operated | Anything running untrusted or model-generated commands — the recommended default for production |

> **Don't skip this:** `UnixLocalSandboxClient` explicitly provides **no OS-level confinement**. If an agent might run commands shaped by a prompt-injected input (the same threat model as `guides/04-mcp.md` (in the agentic-ai course)'s SSRF section), that's a Docker or hosted client, not local.

Windows requires Docker or a hosted provider — there's no local-unix option there.

## Memory: letting later runs learn from earlier ones

`memory()` is worth calling out on its own: it lets a sandbox agent write distilled notes about what it learned (`memories/MEMORY.md`, a short `memory_summary.md`) back into the *workspace itself*, so a later run against the same persisted session starts smarter instead of re-discovering the same things.

- A short summary is injected into the prompt at the start of every run; the agent can dig into the fuller `MEMORY.md` if it needs more detail.
- After a run, an extraction pass summarizes what happened, and a consolidation pass merges it into the workspace's memory files.
- Memory only survives if you keep the same live session, or resume from saved session state / a snapshot — a brand-new sandbox always starts empty.
- `memory({ generate: false })` gives you read-only memory (good for a one-off checker agent); `memory({ read: null })` lets a run generate memory without being influenced by what's already there.

Treat memory files as retained data under your normal workspace sensitivity/retention rules — they're plain files that persist across runs, not an ephemeral scratchpad.

## Composition with handoffs and `asTool()`

- A **handoff** keeps everything inside one top-level run — the sandbox session carries over.
- `agent.asTool()` starts a **nested run with its own turn loop** — same rules as regular agents-as-tools (see `guides/05-agents-sdk.md` (in the agentic-ai course), "Handoffs vs agents-as-tools"), just now operating inside (or against) a sandbox.

## Common mistakes

- **Using `UnixLocalSandboxClient` for anything beyond trusted local dev.** It's explicitly unconfined — there's no sandbox there at all, just your own shell.
- **Passing a custom `capabilities` list and forgetting `shell()` or `filesystem()`** — it replaces the defaults rather than extending them.
- **Expecting memory to persist across unrelated sandbox sessions.** It only survives within one live/resumed session; a fresh sandbox is always a blank slate.
- **Confusing a Manifest with a running session.** The manifest only describes what a *new* workspace starts with — it has no bearing on a session already in progress.

## Check your understanding

1. What's the practical difference between a Manifest and a sandbox session?
   <details><summary>Answer</summary>A Manifest is a declarative description of what a fresh workspace should start with (files, repos, env); a sandbox session is the actual live environment where commands run and files change over the course of a run.</details>
2. Why is `UnixLocalSandboxClient` inappropriate for running commands derived from untrusted or model-generated input?
   <details><summary>Answer</summary>It provides no OS-level confinement — commands run directly on your own machine with no isolation boundary. Use `DockerSandboxClient` or a hosted provider for anything beyond trusted local development.</details>
3. If you pass your own `capabilities` array to a `SandboxAgent`, what happens to the default `filesystem()`/`shell()`/`compaction()` set?
   <details><summary>Answer</summary>It's replaced entirely, not merged — you must explicitly re-list any default capability you still want.</details>

## Next steps

- Compare with this repo's actual tool model (narrow, purpose-built functions instead of an open shell): [`mcp-101.md`](mcp-101.md) and `guides/04-mcp.md` (in the agentic-ai course).
- Resuming paused/long-running work shares ideas with sandbox session resumption: [`human-in-the-loop-101.md`](human-in-the-loop-101.md).
- Official docs: openai.github.io/openai-agents-js/guides/sandbox-agents
