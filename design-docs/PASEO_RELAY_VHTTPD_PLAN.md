# Paseo Relay on `vhttpd` + `vjsx`

This document captures the local analysis for hosting a Paseo-compatible relay
on top of `vhttpd`.

The immediate use case is replacing the official Cloudflare-hosted relay with a
deployment that is faster to reach from mainland China, while keeping protocol
compatibility with the existing Paseo daemon and client implementations.

## Goal

Build a relay endpoint that is behaviorally compatible with
`@getpaseo/relay` without depending on Cloudflare Durable Objects at runtime.

Target outcome:

- clients and daemons can connect to `vhttpd` over WebSocket
- the relay preserves official v1/v2 routing semantics
- encrypted payloads remain opaque to the relay
- protocol drift risk stays low by following the upstream adapter behavior

## Upstream Findings

Local source analyzed:

- `/Users/guweigang/Source/paseo-0.1.56/packages/relay`

What the package actually contains:

- `src/cloudflare-adapter.ts`
  - the relay server implementation for Cloudflare Workers / Durable Objects
- `src/encrypted-channel.ts`
  - a transport wrapper for E2EE handshake and encrypted messaging
- `src/crypto.ts`
  - NaCl-based key exchange and symmetric encryption helpers

Important observation:

- the relay server logic is fairly small
- the package is not a generic standalone relay daemon
- the server implementation is tightly coupled to Cloudflare runtime features
  such as `DurableObjectState`, `WebSocketPair`, WebSocket attachments, and
  hibernation-oriented tags

That means:

- reusing the Cloudflare adapter code verbatim inside `vjsx` is not practical
- reimplementing the adapter behavior on top of `vhttpd` is practical

## Why `vhttpd` is a Good Fit

`vhttpd` already has the right transport model for this work:

- `websocket_dispatch` keeps the live socket inside `vhttpd`
- websocket events are intended to be dispatched as short-lived logic tasks
- the local hub already supports:
  - connection registration
  - metadata
  - room membership
  - targeted send
  - broadcast
  - server-initiated close

Relevant local capabilities:

- `src/main.v`
  - `proxy_worker_websocket_dispatch`
  - `handle_worker_websocket_dispatch_session`
- `src/websocket_runtime.v`
  - hub commands such as `send`, `send_to`, `join`, `leave`, `set_meta`,
    `clear_meta`, `broadcast_dispatch`, `close`

## Main Constraint in Current `vhttpd`

The key missing piece is not the websocket hub.

The missing piece is embedded `vjsx` websocket event handling:

- `InProcVjsxExecutor.dispatch_websocket_event(...)` currently returns
  `inproc_vjsx_executor_not_ready:websocket_event`
- `vjsx` currently supports:
  - HTTP dispatch
  - `websocket_upstream`
  - `startup`
  - `app_startup`
- `vjsx` does not yet support ordinary inbound websocket event handlers

So the first implementation phase is:

- add inbound websocket event dispatch to the in-proc `vjsx` executor

## Why Not Run `@getpaseo/relay` Directly in `vjsx`

This was evaluated and rejected as the first approach.

Reasons:

- the relay server code is written for Cloudflare Durable Objects, not for the
  `vjsx` host runtime
- the package depends on `ws`, which assumes a Node-style websocket client /
  server environment
- `vjsx` currently exposes `httpFetch`, but not a generic outbound `WebSocket`
  host API

So although upstream reuse is still desirable, the useful thing to reuse is:

- the relay semantics
- not the Cloudflare runtime adapter itself

## Compatibility Target

The implementation should mirror the behavior of
`packages/relay/src/cloudflare-adapter.ts`.

### Protocol Versions

Support:

- v1
- v2

Prefer implementing v2 first because it is the current shape used by the
official relay path.

### v1 Model

One session has:

- one `server` socket
- one `client` socket

Messages are forwarded bidirectionally without interpretation.

### v2 Model

One session has three socket roles:

- `server-control`
  - `role=server`
  - no `connectionId`
- `server-data`
  - `role=server`
  - with `connectionId`
- `client`
  - `role=client`
  - with `connectionId`

Relay-side control messages:

- `sync`
- `connected`
- `disconnected`
- `ping` / `pong`

Opaque data forwarding:

- `client(connectionId)` -> `server-data(connectionId)`
- `server-data(connectionId)` -> all `client(connectionId)` sockets

Buffering rule:

- if a client sends before the matching `server-data` socket is available,
  buffer frames for that `connectionId`
- cap the buffer to avoid unbounded memory growth

## Mapping from Cloudflare Adapter to `vhttpd`

### Durable Object instance

Cloudflare concept:

- one Durable Object instance per `serverId` session

`vhttpd` mapping:

- one in-memory relay session entry per `serverId`
- held by the `vjsx` app state

### WebSocket tags

Cloudflare concept:

- `server-control`
- `server:${connectionId}`
- `client:${connectionId}`

`vhttpd` mapping:

- connection metadata:
  - `relay_server_id`
  - `relay_role`
  - `relay_version`
  - `relay_connection_id`
- optional rooms:
  - `relay:session:<serverId>`
  - `relay:conn:<serverId>:<connectionId>`

### Attachment state

Cloudflare concept:

- serialized attachment on each websocket

`vhttpd` mapping:

- metadata stored in the websocket hub
- in-memory relay session state stored in the `vjsx` app

## Recommended `vjsx` Relay State

Suggested shape:

```ts
type RelaySession = {
  version: "1" | "2";
  controlIds: Set<string>;
  v1ServerId?: string;
  v1ClientIds: Set<string>;
  serverDataByConnection: Map<string, string>;
  clientIdsByConnection: Map<string, Set<string>>;
  pendingFramesByConnection: Map<string, string[]>;
};
```

Session state is transient and in-memory.

That is acceptable for relay use because:

- the official Durable Object flow is also effectively session-local runtime
  state
- if the relay process restarts, clients and daemons should reconnect and
  rebuild the session

## Required `vjsx` WebSocket API

To make relay apps possible in embedded mode, `vjsx` should support a normal
websocket handler analogous to the existing `websocket_upstream` support.

Recommended exported handler names:

- `websocket`
- `handleWebSocket`
- `handle_websocket`

Recommended frame shape:

- `frame.mode`
- `frame.event`
- `frame.id`
- `frame.path`
- `frame.query`
- `frame.headers`
- `frame.remoteAddr`
- `frame.requestId`
- `frame.traceId`
- `frame.rooms`
- `frame.metadata`
- `frame.roomMembers`
- `frame.memberMetadata`
- `frame.roomCounts`
- `frame.presenceUsers`
- `frame.opcode`
- `frame.data`
- `frame.code`
- `frame.reason`
- `frame.runtime`

Recommended helper methods:

- `frame.dataText(fallbackValue)`
- `frame.dataJson(fallbackValue)`

Recommended return shape:

- `false` or `null`
  - `{ accepted: false, commands: [] }`
- `true`
  - `{ accepted: true, commands: [] }`
- `Command[]`
  - `{ accepted: true, commands }`
- `{ accepted?, closed?, commands?, error?, errorClass? }`

The command list should reuse the existing websocket hub commands already
implemented in `vhttpd`.

## Implementation Phases

### Phase 1: `vjsx` inbound websocket dispatch

Implement:

- `InProcVjsxExecutor.dispatch_websocket_event(...)`
- JS-side websocket frame construction
- JS-side websocket result normalization
- handler resolution for `websocket`

This phase is a prerequisite for the relay app.

### Phase 2: minimal relay app in `vjsx`

Implement a `vjsx` app that:

- accepts `/ws`
- reads:
  - `serverId`
  - `role`
  - `connectionId`
  - `v`
- tracks sessions in memory
- supports:
  - v2 control connect
  - v2 client connect
  - v2 server-data connect
  - `sync`
  - `connected`
  - `disconnected`
  - buffered forward

### Phase 3: v1 compatibility

Add:

- legacy single server/client relay semantics

### Phase 4: binary-frame parity

Current `websocket_dispatch` in `vhttpd` only accepts text frames.

For stronger relay compatibility, extend the runtime to preserve:

- text frames
- binary frames

This is desirable because the upstream relay tests also exercise binary
websocket payload delivery.

## Risks

### Protocol drift

Risk:

- upstream relay behavior changes over time

Mitigation:

- keep the local relay app behavior intentionally close to
  `cloudflare-adapter.ts`
- document which upstream version the implementation targets

### Binary websocket compatibility

Risk:

- current websocket dispatch path is text-only

Mitigation:

- start with text-compatible relay behavior
- add binary support as a follow-up runtime enhancement

### Session volatility

Risk:

- restart drops active relay sessions

Mitigation:

- acceptable for the relay use case
- clients and daemons are expected to reconnect

## Recommended Near-Term Work

Immediate next steps:

1. implement inbound websocket event support for `vjsx`
2. add tests for embedded websocket event dispatch
3. scaffold a `vjsx` relay app skeleton
4. implement v2 routing semantics before v1

That gives `vhttpd` the right foundation for a Paseo-compatible relay without
forcing `vjsx` to emulate Cloudflare Durable Objects or Node's `ws` runtime.
