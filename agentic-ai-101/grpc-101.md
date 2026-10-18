# gRPC 101 — from zero

> A quick, standalone primer. This repo doesn't use gRPC anywhere (its MCP servers use JSON-RPC over HTTP instead — see [`mcp-101.md`](mcp-101.md)), but it's one of the most common RPC frameworks you'll meet in real backend systems, and worth knowing for contrast.

## What it is

**gRPC** ("gRPC Remote Procedure Call") is an open-source RPC framework originally built at Google, now a CNCF project. Instead of calling a URL and parsing JSON, you call a **method on a service** almost as if it were a local function — the framework handles serializing the call, sending it over the network, and deserializing the response.

```ts
// feels like calling a local function…
const response = await client.getUser({ id: "42" });
// …but it's actually a network call to another service
```

Three things make gRPC distinctive compared to a typical REST+JSON API:

1. **Protocol Buffers ("protobuf")** — a compact binary format for messages, generated from a schema.
2. **HTTP/2** as the transport — multiplexed streams, header compression, real bidirectional streaming.
3. **Strongly-typed contracts** — the same `.proto` file generates client and server code in many languages, so both sides agree on the shape of every call at compile time.

## The core artifact: the `.proto` file

Everything starts with a schema file written in Protocol Buffers' interface definition language:

```protobuf
syntax = "proto3";

package users;

service UserService {
  rpc GetUser (GetUserRequest) returns (User);
  rpc ListUsers (ListUsersRequest) returns (stream User); // server streaming
}

message GetUserRequest {
  string id = 1;
}

message User {
  string id = 1;
  string name = 2;
  string email = 3;
}

message ListUsersRequest {
  int32 page_size = 1;
}
```

A compiler (`protoc`, or a language-specific plugin) turns this one file into:

- **Server stub** — base classes/interfaces you implement with your actual business logic.
- **Client stub** — a typed client your application code calls directly, with no manual URL-building or JSON parsing.
- **Message classes** — typed objects for `User`, `GetUserRequest`, etc., with built-in binary (de)serialization.

The numbers after each field (`= 1`, `= 2`, …) aren't display order — they're the **wire tags** protobuf uses to identify fields in the binary encoding. This is also how protobuf achieves safe schema evolution: you can add new fields with new numbers without breaking old clients, but you must never reuse a retired field's number.

## Why binary + HTTP/2 instead of JSON + HTTP/1.1

| | REST + JSON | gRPC |
|---|---|---|
| Payload | Text (JSON) — human-readable, larger | Binary (protobuf) — compact, faster to parse |
| Transport | Usually HTTP/1.1 (one request waits for one response per connection, or pipelining workarounds) | HTTP/2 (many concurrent streams over one connection) |
| Contract | Often informal (an OpenAPI spec, if you're disciplined) | Enforced by the `.proto` file; client and server are generated from the same source of truth |
| Streaming | Awkward (long polling, SSE, WebSockets bolted on) | Native: server streaming, client streaming, and bidirectional streaming are all first-class RPC shapes |
| Browser support | Universal | Needs a proxy (gRPC-Web) — browsers can't speak raw HTTP/2 trailers the way gRPC needs |
| Human debugging | `curl` + readable JSON | Needs a gRPC-aware tool (`grpcurl`, `buf curl`, Postman's gRPC support) since payloads are binary |

The trade-off is debuggability and reach (anyone with a browser can call a REST API) versus speed and type safety (gRPC is built for service-to-service traffic inside a trusted network, not for public-facing browser APIs).

## The four call shapes

This is the part REST can't do natively:

| Shape | Direction | Example |
|---|---|---|
| **Unary** | one request → one response | `GetUser(id)` → `User` |
| **Server streaming** | one request → a stream of responses | `ListUsers()` → stream of `User` as they're found |
| **Client streaming** | a stream of requests → one response | upload chunks of a file → one "upload complete" response |
| **Bidirectional streaming** | both sides stream independently | a live chat, or a long-running negotiation between two services |

All four reuse the same HTTP/2 connection — streams are multiplexed, so a slow streaming call doesn't block other calls on the same connection the way it might over HTTP/1.1.

## A minimal server (Node.js, `@grpc/grpc-js`)

```ts
import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";

const packageDef = protoLoader.loadSync("users.proto");
const proto = grpc.loadPackageDefinition(packageDef) as any;

const server = new grpc.Server();
server.addService(proto.users.UserService.service, {
  getUser: (call, callback) => {
    const { id } = call.request;
    callback(null, { id, name: "Ada Lovelace", email: "ada@example.com" });
  },
});
server.bindAsync("0.0.0.0:50051", grpc.ServerCredentials.createInsecure(), () => server.start());
```

```ts
// client
const client = new proto.users.UserService("localhost:50051", grpc.credentials.createInsecure());
client.getUser({ id: "42" }, (err, user) => console.log(user));
```

Notice there's no manual JSON parsing, no hand-written URL path, and no REST verb to pick — just a method call with a typed argument.

## gRPC vs MCP's JSON-RPC

Both are RPC-style protocols, but built for different jobs:

| | gRPC | MCP (JSON-RPC over HTTP) |
|---|---|---|
| Built for | service-to-service calls inside a backend | giving an LLM host access to tools/resources |
| Payload | binary (protobuf) | JSON (human-readable, easy to log and debug) |
| Schema | `.proto` compiled ahead of time | JSON Schema, discovered at runtime via `tools/list` |
| Typical consumer | another backend service, same team/org | an AI model deciding dynamically what to call |

MCP chose JSON-RPC precisely because its "client" (the model) needs to discover capabilities at runtime and the payloads benefit from being human-readable for debugging and for the model itself to reason about — gRPC's ahead-of-time compiled, binary approach optimizes for a different goal: raw throughput between services whose contracts are fixed at build time. See [`mcp-101.md`](mcp-101.md) for the full MCP picture.

## When to reach for gRPC

Good fit:
- Internal microservice-to-microservice calls where both ends are services you control.
- High request volume where binary encoding and HTTP/2 multiplexing meaningfully cut latency/CPU.
- You need real streaming (e.g. a service pushing live updates to another service).

Less of a fit:
- Public APIs consumed directly by browsers (needs a gRPC-Web proxy, extra infrastructure).
- APIs where human-readability/debuggability with plain `curl` matters more than raw performance.
- Simple CRUD APIs with low traffic, where REST's simplicity and ubiquity win.

## Common mistakes

- **Reusing or renumbering protobuf field tags** after a message has shipped — this silently corrupts data for clients still using the old schema.
- **Expecting a browser to call gRPC directly** — you need gRPC-Web (or REST-to-gRPC gateway) in between.
- **Treating gRPC errors like HTTP status codes** — gRPC has its own status code set (`NOT_FOUND`, `UNAVAILABLE`, `DEADLINE_EXCEEDED`, …) carried in trailers, not a simple top-level HTTP status.
- **Skipping deadlines** — gRPC calls should set a deadline/timeout explicitly; without one, a slow downstream service can hang a call indefinitely.

## Check your understanding

1. Why can gRPC do bidirectional streaming natively while REST needs WebSockets or SSE bolted on?
   <details><summary>Answer</summary>gRPC runs over HTTP/2, which supports multiple concurrent, independent streams over a single connection — streaming is part of the core RPC model. REST is built around the one-request/one-response HTTP/1.1 model, so continuous two-way communication has to be added separately.</details>
2. What do the numbers in `string id = 1;` inside a `.proto` message actually mean?
   <details><summary>Answer</summary>They're wire tags used to identify each field in the compact binary encoding — not display order. They must stay stable and unique over a message's lifetime so old and new clients can still read each other's messages.</details>
3. Why might you choose JSON-RPC (as MCP does) over gRPC for letting an LLM call tools?
   <details><summary>Answer</summary>JSON is human-readable, easy to log/debug, and lets the model's host discover tool schemas dynamically at runtime (`tools/list`) rather than requiring a pre-compiled, ahead-of-time schema like a `.proto` file.</details>

## Next steps

- Compare with this repo's actual RPC protocol: [`mcp-101.md`](mcp-101.md) and the hands-on `guides/04-mcp.md` (in the agentic-ai course).
- Official docs: grpc.io
