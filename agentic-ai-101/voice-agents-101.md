# Voice Agents 101 — OpenAI Agents SDK

> A quick, standalone primer. This repo's chat app is text-only, streaming responses over SSE (see `guides/05-agents-sdk.md` (in the agentic-ai course), "Streaming to the browser"). Voice agents solve a related but distinct problem: real-time speech-to-speech, not text turns.

## What it is

A **voice agent** talks to the user with actual audio in both directions, in real time — not "speech-to-text → run the text agent → text-to-speech" bolted together, but a model that natively processes and produces audio with low latency, including being interrupted mid-sentence.

Two new pieces, alongside the `Agent` you already know:

- **`RealtimeAgent`** — created almost identically to a regular `Agent` (`name`, `instructions`). It's *what* the user talks to.
- **`RealtimeSession`** — the runtime that keeps a voice conversation alive: the model connection, audio capture/playback, turn-taking, interruptions. A text `Agent` has no equivalent of this — a voice agent *lives inside* a session for the duration of the call.

```ts
import { RealtimeAgent, RealtimeSession } from "@openai/agents/realtime";

const agent = new RealtimeAgent({
  name: "Assistant",
  instructions: "You are a helpful assistant.",
});

const session = new RealtimeSession(agent, { model: "gpt-realtime-2.1" });

await session.connect({ apiKey: "ek_..." }); // an EPHEMERAL token, not your real API key
```

Everything else you already know still applies: tools, handoffs, and guardrails all work the same way inside a `RealtimeAgent` as they do in a text `Agent`.

## Ephemeral tokens: never put a real API key in the browser

A voice agent usually runs *in the browser* (it needs the microphone), but your real OpenAI/Azure API key must never ship to client code. The fix: your backend calls `POST /v1/realtime/client_secrets` with your real key and gets back a short-lived `ek_`-prefixed token, which it hands to the browser. The browser calls `session.connect({ apiKey: "ek_..." })` with *that* instead.

Same principle as the Entra-ID-over-API-key guidance in `guides/03-azure-openai.md` (in the agentic-ai course): minimize what's trusted with a long-lived secret, hand the client the smallest, shortest-lived thing that works.

## Picking a transport

| Scenario | Transport | Why |
|---|---|---|
| Browser speech-to-speech | **WebRTC** (default) | SDK manages microphone capture, playback and the connection for you — lowest friction |
| Browser audio, server-side logic | App-owned WebRTC audio + a server-side `RealtimeSession` | Events/tools/business logic stay server-side; browser only carries audio |
| React Native | App-owned `RealtimeTransportLayer` over native WebRTC | The built-in WebRTC transport is browser-only |
| Server-side voice loop / custom audio pipeline | **WebSocket** (default outside the browser) | Direct event access when you control audio capture/playback yourself |
| SIP / telephony bridge | `OpenAIRealtimeSIP` | Attaches to an existing SIP call by `callId` |
| Cloudflare Workers | Cloudflare extension transport | `workerd` can't open outbound WebSockets the normal way |
| Twilio phone calls | Twilio extension transport | Handles Twilio audio forwarding + interruption timing |

Rule of thumb from the docs: **browser product with no need to touch raw audio → start with WebRTC. Server-side or bridging work → start with WebSocket or SIP.**

### WebRTC (the browser default)

```ts
const session = new RealtimeSession(agent, { model: "gpt-realtime-2.1" });
await session.connect({ apiKey: "ek_..." });
// mic access + playback + the peer connection are all handled for you
```

`connect()` waits for a `session.updated` acknowledgement (so your instructions/tools are actually applied before audio starts), with a timeout fallback. You can supply your own `MediaStream`/audio element, or hook `changePeerConnection` to inspect or modify the `RTCPeerConnection` before the offer is generated.

> **Security note:** the built-in WebRTC transport opens a data channel for events — that channel is **not a server-enforced trust boundary**. If you need real policy enforcement (what tools can fire, what they're allowed to do), keep that logic server-side and authorize against context *you* trust, not arguments the model supplied over that channel — the same principle as [`context-management-101.md`](context-management-101.md)'s point about `isEnabled` not being a security boundary.

**Azure OpenAI specifics:** requires the GA protocol, an ephemeral token minted by your server, the deployment name passed as `model`, and you must not strip `session.type` from the config.

### WebSocket (the server default)

```ts
const session = new RealtimeSession(agent, {
  transport: "websocket",
  model: "gpt-realtime-2.1",
});
await session.connect({ apiKey: process.env.OPENAI_API_KEY! });
session.on("audio", (event) => { /* handle a raw PCM16 chunk */ });
session.sendAudio(audioBuffer);
```

Audio here is raw PCM16 that you send/receive yourself via `sendAudio()` / the `audio` event — appropriate when you already own the audio pipeline (e.g. bridging to a telephony system).

### Everything else (SIP, Cloudflare, Twilio, custom)

- **SIP** — `OpenAIRealtimeSIP` attaches to an existing call by `callId`; its `buildInitialConfig()` helper deliberately rejects turn-detection fields (`threshold`, `prefixPaddingMs`, `silenceDurationMs`) that SIP sessions don't support.
- **Cloudflare Workers / Twilio** — dedicated transports from `@openai/agents-extensions` handle the platform-specific plumbing (Workers can't open outbound WebSockets the normal way; Twilio needs specific interruption/audio-forwarding handling).
- **Custom transport** — implement `RealtimeTransportLayer` yourself and emit the SDK's `RealtimeTransportEventTypes` if you need to speak to a different speech-to-speech API entirely.

## Common mistakes

- **Shipping a real API key to the browser.** Always mint an ephemeral `ek_` token server-side.
- **Treating the WebRTC data channel as an access-control boundary.** It isn't — enforce policy and authorize tool actions on the server, against context you trust.
- **Expecting the browser-only WebRTC transport to work in React Native.** It doesn't — you need a native WebRTC library wired through a custom `RealtimeTransportLayer` (and a dev build, since Expo Go can't load the native code).
- **Including turn-detection fields in a SIP session's initial config.** `buildInitialConfig()` throws on `threshold`/`prefixPaddingMs`/`silenceDurationMs` — SIP doesn't support them.

## Check your understanding

1. Why does the browser connect with an `ek_`-prefixed token instead of your real API key?
   <details><summary>Answer</summary>The browser is untrusted code from a security standpoint — a real, long-lived API key embedded there could be extracted and reused. An ephemeral client token, minted server-side and short-lived, limits the blast radius if it leaks.</details>
2. Why is the WebRTC data channel described as not being a server-enforced boundary?
   <details><summary>Answer</summary>The built-in transport creates the data channel for events on the client side; nothing stops a motivated client from sending arbitrary events over it. Real policy enforcement and tool authorization need to happen server-side, against trusted context — not by relying on what the browser chooses to send.</details>
3. When would you reach for WebSocket instead of the default WebRTC transport?
   <details><summary>Answer</summary>When running server-side (outside a browser), when you need direct low-level event/audio access, or when bridging to another audio pipeline (e.g. telephony) where you already own audio capture and playback.</details>

## Next steps

- Tool approval (`needsApproval`) and `RunContext` both apply the same way inside a `RealtimeAgent` as in a text agent: [`human-in-the-loop-101.md`](human-in-the-loop-101.md), [`context-management-101.md`](context-management-101.md).
- This repo's text-streaming equivalent, for contrast: `guides/05-agents-sdk.md` (in the agentic-ai course), "Streaming to the browser".
- Official docs: openai.github.io/openai-agents-js/guides/voice-agents
