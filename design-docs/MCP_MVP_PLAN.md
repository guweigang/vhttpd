# MCP MVP Plan for `vhttpd`

This document proposes how `vhttpd` should support MCP as a transport/runtime layer, without turning `vhttpd` into an MCP application framework.

## Scope

Target the current official MCP transport model:

- latest transport spec observed during design: `2025-11-25`
- official transports:
  - `stdio`
  - `Streamable HTTP`

For `vhttpd`, the correct first target is:

- `Streamable HTTP` only

Not in scope for the first MVP:

- stdio MCP server mode
- provider-specific MCP application logic
- OAuth authorization
- MCP Registry support
- backwards compatibility with deprecated `HTTP+SSE` MCP transport

`stdio` should not be implemented inside `vhttpd`.

`sampling` is also not part of the first MCP transport MVP implementation.
It should be added later as a relay/runtime feature on top of the same Streamable HTTP session model.

Recommended boundary:

- `vhttpd`
  - Streamable HTTP MCP
- `vshx` (or another local CLI runtime)
  - stdio MCP

## Why `vhttpd` fits MCP

`vhttpd` already has the right building blocks:

- short-lived worker dispatch
- SSE transport ownership in `vhttpd`
- session-like runtime state for websocket/upstream flows
- admin/runtime visibility
- PHP worker contract already separated from connection ownership

That means MCP should be implemented as:

- `vhttpd` owns MCP transport
- PHP worker owns MCP method handling

Not as:

- `vhttpd` hardcoding MCP tools/resources/prompts behavior

## Vlib Reuse Matrix

Before implementing MCP, the relevant `vlib` pieces were re-checked against the local `vlib` source and current module docs.

### Reuse directly

- `net.http`
  - use for MCP HTTP request/response semantics
  - header parsing, status codes, request helpers, upstream helpers
  - already central in `vhttpd`

- `veb`
  - keep using `veb` as the HTTP server/runtime source of truth
  - MCP should remain just another runtime transport on top of `veb`

- `veb.sse`
  - useful for SSE formatting and transport behavior
  - especially valuable for `GET /mcp` stream handling
  - good fit because MCP Streamable HTTP still uses `text/event-stream`

- `sync`
  - channels, mutexes, rwmutexes, waitgroups
  - this should remain the primary primitive set for session registries, queues, and cleanup loops

### Reuse partially / with caution

- `net.jsonrpc`
  - useful as a reference for JSON-RPC data model and handler shape
  - not a good transport fit for MCP-over-HTTP in `vhttpd`
  - current `net.jsonrpc.Server` is stream-oriented and assumes Content-Length framing over an `io.ReaderWriter`
  - that is much closer to MCP `stdio` than MCP Streamable HTTP
  - recommendation:
    - reuse concepts, not the server as-is

- `eventbus`
  - acceptable for internal notifications or low-priority hooks
  - not a good fit as the primary MCP session/message store
  - it is synchronous pub/sub, not a session runtime

- `pool.ConnectionPool`
  - potentially useful later for outbound upstream optimization
  - not needed for MCP transport MVP
  - should not be the foundation of session handling

### Do not use as MCP transport core

- `net.websocket`
  - excellent for websocket support, but MCP MVP should start with Streamable HTTP
  - may become relevant later only if websocket-based MCP transport is explored

- `sync.pool`
  - useful for batch/parallel task execution
  - not suitable as the core abstraction for MCP sessions or message queues

## Practical Conclusion

For MCP MVP, the correct base is:

- `veb`
- `net.http`
- `veb.sse`
- `sync`

while avoiding the temptation to force-fit:

- `net.jsonrpc.Server`
- `eventbus`
- `pool.ConnectionPool`
- `sync.pool`

This keeps the implementation aligned with the rest of `vhttpd`:

- transport/session ownership in `vhttpd`
- business semantics in PHP worker

## Design Principle

`vhttpd` should become an **MCP transport adapter**, not an MCP business framework.

Layer split:

- `vhttpd`
  - HTTP transport
  - SSE stream handling
  - session registry
  - version/header validation
  - origin/auth hooks
  - observability
- PHP worker
  - JSON-RPC request handling
  - MCP method routing
  - server feature implementation
- VSlim / package helpers
  - userland API for tools/resources/prompts

## MCP Facts That Shape The Design

Based on the current official MCP transport specification:

- MCP uses JSON-RPC messages.
- Streamable HTTP uses a single MCP endpoint path.
- client messages are sent via `HTTP POST`
- the server may answer with either:
  - `application/json`
  - `text/event-stream`
- clients may open a separate `HTTP GET` SSE stream to receive server-to-client messages
- sessions may be established with `Mcp-Session-Id`
- clients should send `MCP-Protocol-Version`
- servers must validate `Origin` on HTTP transports

This strongly matches `vhttpd`'s existing phase-2/phase-3 runtime direction.

## Proposed Endpoint Shape

Use a single endpoint, for example:

- `POST /mcp`
- `GET /mcp`
- optional `DELETE /mcp`

Semantics:

- `POST /mcp`
  - accepts one JSON-RPC request / notification / response
  - returns JSON or SSE
- `GET /mcp`
  - opens server-to-client SSE stream
- `DELETE /mcp`
  - terminates `Mcp-Session-Id` if supported

## Runtime Model

Introduce a new worker surface:

- `mode = mcp`

High-level flow:

```text
MCP client
  -> POST /mcp
  -> vhttpd validates headers/session/version/origin
  -> vhttpd dispatches one short MCP envelope to php-worker
  -> php-worker returns one of:
     - JSON-RPC response
     - SSE command list / deferred messages
     - session commands
  -> vhttpd writes JSON or SSE response
```

For server-initiated messages:

```text
MCP client
  -> GET /mcp
  -> vhttpd binds SSE stream to session
  -> later worker requests/notifications are queued to that session stream
```

## Session Ownership

Sessions should live in `vhttpd`, not in PHP worker memory.

Session state stored in `vhttpd`:

- `session_id`
- negotiated protocol version
- active GET SSE stream, if any
- pending outbound JSON-RPC messages
- created_at / last_seen
- optional auth principal summary

This follows the same principle as websocket phase 2:

- connection/session ownership in `vhttpd`
- business handling in worker

## Worker Contract Draft

Incoming request from `vhttpd` to PHP worker:

```json
{
  "mode": "mcp",
  "event": "message",
  "session_id": "mcp_sess_123",
  "transport": "streamable_http",
  "http_method": "POST",
  "path": "/mcp",
  "protocol_version": "2025-11-25",
  "headers": {
    "accept": "application/json, text/event-stream",
    "mcp-protocol-version": "2025-11-25"
  },
  "jsonrpc": {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {}
  }
}
```

Worker response draft:

```json
{
  "mode": "mcp",
  "handled": true,
  "response_mode": "json",
  "session": {
    "create": true,
    "id": "mcp_sess_123"
  },
  "jsonrpc": {
    "jsonrpc": "2.0",
    "id": 1,
    "result": {}
  }
}
```

Or SSE-style response:

```json
{
  "mode": "mcp",
  "handled": true,
  "response_mode": "sse",
  "session": {
    "id": "mcp_sess_123"
  },
  "messages": [
    {
      "type": "jsonrpc",
      "data": {
        "jsonrpc": "2.0",
        "method": "notifications/progress",
        "params": {}
      }
    },
    {
      "type": "jsonrpc",
      "data": {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {}
      }
    }
  ]
}
```

## Phase Breakdown

### Phase A: Transport MVP

Goal:

- accept `POST /mcp`
- validate `MCP-Protocol-Version`
- dispatch a single JSON-RPC request to PHP worker
- return `application/json`

No SSE GET session stream yet.
No server-initiated notifications yet.

Current implementation target:

- `POST /mcp` only
- `GET /mcp` returns `405`
- PHP worker mode: `mcp`
- helper: `VPhp\VSlim\Mcp\App`

This is the smallest useful MCP baseline.

### Phase B: Streamable HTTP MVP

Goal:

- add `GET /mcp`
- add `Mcp-Session-Id`
- allow `POST /mcp` to respond with `text/event-stream`
- support queued server-to-client JSON-RPC messages

This is the first version that really feels like modern MCP Streamable HTTP.

Current implementation target:

- `POST /mcp`
  - JSON-only request/response still supported
  - response sets `Mcp-Session-Id` when session is created
- `GET /mcp`
  - requires `Mcp-Session-Id`
  - upgrades to `text/event-stream`
  - keeps the session open with keepalive comments
- queued server notifications
  - PHP worker may return `messages[]`
  - `vhttpd` queues them per session
  - active `GET /mcp` stream flushes them as SSE `data:` JSON frames
- helper extension:
  - `VPhp\VSlim\Mcp\App` supports response arrays with `messages`
  - `App::tool(...)` can provide builtin `tools/list` and `tools/call`
  - `App::resource(...)` can provide builtin `resources/list` and `resources/read`
  - `App::prompt(...)` can provide builtin `prompts/list` and `prompts/get`

Current limitations:

- no resumability
- `initialize` session creation is still inferred from current request flow
- POST does not yet return `text/event-stream`

### Phase C: Hardening

Goal:

- strict `Origin` validation
- auth hooks
- admin/runtime visibility for MCP sessions
- expiry / cleanup / pending queue limits
- resumability discussion

Current implementation target:

- `/admin/runtime/mcp`
  - summary by default
  - `details=1`
  - `limit/offset`
  - `session_id` / `protocol_version` filters
- bounded session memory
  - `mcp.max_sessions`
  - `mcp.max_pending_messages`
  - `mcp.session_ttl_seconds`
- automatic pruning
  - stale sessions expire by TTL
  - pending queues are truncated to configured max
- transport guardrails
  - optional `allowed_origins` allowlist
  - `DELETE /mcp` session termination

Still pending:

- auth hook integration beyond existing admin token pattern
- resumability / reconnect semantics

## Why Not Start With Full MCP Features

MCP includes a lot more than transport:

- initialization/lifecycle
- tools
- resources
- prompts
- completions
- sampling / elicitation
- authorization

Those should mostly live above `vhttpd`.

`vhttpd` should care first about:

- transport correctness
- session correctness
- SSE correctness
- worker contract correctness

## Security Requirements For MVP

Even the MVP should enforce:

- `Origin` validation for HTTP transport
- bind local deployments to `127.0.0.1` by default
- configurable auth hook/token support
- protocol-version validation
- bounded session and pending message memory

## Observability Requirements

Runtime visibility now includes:

- `/admin/runtime`
  - `mcp_enabled`
  - `active_mcp_sessions`
- `/admin/runtime/mcp`
  - session summaries
  - pending outbound counts
  - negotiated protocol versions
  - configured limits and allowlist

Relevant runtime counters now include:

- `mcp_sessions_expired_total`
- `mcp_sessions_evicted_total`
- `mcp_pending_dropped_total`

This follows the same philosophy as websocket/upstream admin visibility:

- default summary
- details only when requested

Current config surface:

- `[mcp].max_sessions`
- `[mcp].max_pending_messages`
- `[mcp].session_ttl_seconds`
- `[mcp].allowed_origins`

When `allowed_origins` is non-empty:

- `POST /mcp` requires a matching `Origin`
- `GET /mcp` requires a matching `Origin`
- `DELETE /mcp` requires a matching `Origin`

## Recommendation

Implement MCP in this order:

1. `POST /mcp` JSON-only MVP
2. `GET /mcp` + `Mcp-Session-Id`
3. SSE response mode on POST
4. admin/runtime MCP visibility
5. auth/origin hardening

This keeps `vhttpd` focused on what it already does well:

- protocol transport
- session/runtime ownership
- worker orchestration

while leaving MCP application semantics in PHP userland.
