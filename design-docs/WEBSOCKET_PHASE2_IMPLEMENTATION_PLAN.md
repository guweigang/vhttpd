# WebSocket Phase 2 Implementation Plan

This document turns the earlier phase-2 direction into an implementable plan.

Phase 1 solved single-node multi-worker fanout by moving room membership and
connection metadata into `vhttpd`, while still keeping one PHP worker attached
to one live WebSocket session.

Phase 2 changes that execution model:

- WebSocket connections stay in `vhttpd`
- PHP workers no longer own a connection for its full lifetime
- each `open` / `message` / `close` event is dispatched as a short-lived worker task
- workers return a command list
- `vhttpd` executes those commands against its local connection hub

That is the point where connection count and worker count are finally decoupled.

## Goals

- make thousands of idle WebSocket connections possible without thousands of PHP workers
- keep room membership, metadata, and presence in `vhttpd`
- let PHP workers stay stateless between websocket events
- reuse existing `vhttpd` local hub and room fanout logic as much as possible
- keep the worker transport simple and purpose-built

## Non-goals for Phase 2

- multi-node cluster protocol
- durable message persistence
- binary frame support beyond the current minimal model
- replacing the existing phase-1 model immediately

Phase 2 should coexist with phase 1 first.

## Current MVP status

The first MVP slice is now implemented behind `worker.websocket_dispatch = true`.

What is already verified:

- websocket connections stay in `vhttpd`
- worker interaction is short-lived request/response per event
- command-list execution works for `send`, `close`, `join`, `broadcast`, `set_meta`
- two websocket clients can connect and chat with `worker.pool_size = 1`

That confirms the core architectural goal:

- connection count and PHP worker count are no longer tightly coupled

## Reusable vlib pieces

Use these:

- `net.websocket`
  protocol, handshake, ping/pong, frame parsing, close lifecycle
- `sync`
  channels, mutexes, rwmutexes, threads, cond vars
- `veb.sse`
  as a reference for long-lived connection ownership on the server side

Use only as helpers:

- `eventbus`
  optional internal notifications, metrics hooks, non-critical observers

Do not use as the phase-2 core:

- `sync.pool`
  designed for parallel batch work, not event-driven connection dispatch
- `pool`
  designed for borrow/return resources, not websocket session orchestration

## High-level model

```text
browser
  -> vhttpd websocket connection
  -> local websocket hub
  -> event dispatcher
  -> short-lived php-worker task
  -> worker command list
  -> vhttpd executes commands
  -> browser
```

The worker does not keep the socket open.

## Core responsibilities

### vhttpd

- own all live websocket connections
- own room membership and metadata
- build event payloads for `open`, `message`, `close`
- choose an available worker for each event
- execute returned commands:
  - `send`
  - `close`
  - `join`
  - `leave`
  - `broadcast`
  - `send_to`
  - `set_meta`
  - `clear_meta`
- enforce timeouts and fallback error handling

### php-worker

- receive one websocket event payload
- load bootstrap app
- invoke the event handler
- collect command list
- return commands
- exit request scope for that event

### userland app

- process event payload
- return actions, not ownership
- treat connection state as externalized metadata

## Data structures in vhttpd

These are the main in-memory structures.

```v
struct WsConnState {
    id          string
    request_id  string
    trace_id    string
    path        string
    remote_addr string
mut:
    client      &websocket.Client = unsafe { nil }
    headers     map[string]string
    query       map[string]string
    metadata    map[string]string
    rooms       map[string]bool
    opened_at   i64
    last_seen   i64
}

struct WsEventEnvelope {
    kind            string // open|message|close
    conn_id         string
    request_id      string
    trace_id        string
    path            string
    remote_addr     string
    query           map[string]string
    headers         map[string]string
    opcode          string
    data            string
    code            int
    reason          string
    rooms           []string
    metadata        map[string]string
    room_members    map[string][]string
    member_metadata map[string]map[string]string
    room_counts     map[string]int
    presence_users  map[string][]string
}

struct WsCommand {
    event      string
    id         string
    target_id  string
    room       string
    key        string
    value      string
    except_id  string
    opcode     string
    data       string
    code       int
    reason     string
}
```

The existing phase-1 hub maps can mostly stay:

- `conn_id -> WsConnState`
- `room -> members`
- `conn_id -> rooms`
- `conn_id -> metadata`

Phase 2 should reuse those instead of inventing a second registry.

## Event dispatch loop

### Open

1. `vhttpd` accepts websocket upgrade
2. `net.websocket` completes handshake
3. `vhttpd` registers the connection locally
4. `vhttpd` builds an `open` event envelope
5. `vhttpd` picks an available worker
6. worker returns command list
7. `vhttpd` executes commands

There is no worker-owned duplex loop.

### Message

1. client sends text frame
2. `vhttpd` receives frame via `net.websocket`
3. `vhttpd` updates `last_seen`
4. `vhttpd` builds `message` envelope using current metadata and room snapshot
5. `vhttpd` sends one request to a free worker
6. worker returns command list
7. `vhttpd` executes commands

### Close

1. connection closes or is closed by server
2. `vhttpd` builds `close` envelope using final snapshots
3. worker may return final commands like `broadcast room left`
4. `vhttpd` executes commands
5. `vhttpd` unregisters the connection

## Worker transport shape

Phase 2 should not reuse the current long-lived `mode=websocket` duplex loop as-is.

Instead, add a request/response event-dispatch mode.

### Request frame

```json
{
  "mode": "websocket_dispatch",
  "event": "message",
  "id": "conn-123",
  "request_id": "req-123",
  "trace_id": "req-123",
  "path": "/ws",
  "remote_addr": "127.0.0.1:54321",
  "query": {"room": "lobby", "user": "alice"},
  "headers": {"origin": "http://127.0.0.1:19891"},
  "opcode": "text",
  "data": "{\"text\":\"hello\"}",
  "rooms": ["lobby"],
  "metadata": {"user": "alice", "presence": "online"},
  "room_members": {"lobby": ["conn-123", "conn-456"]},
  "member_metadata": {
    "conn-123": {"user": "alice", "presence": "online"},
    "conn-456": {"user": "bob", "presence": "online"}
  },
  "room_counts": {"lobby": 2},
  "presence_users": {"lobby": ["alice", "bob"]}
}
```

### Response frame

```json
{
  "mode": "websocket_dispatch",
  "event": "result",
  "id": "conn-123",
  "commands": [
    {"event": "broadcast", "room": "lobby", "data": "...", "opcode": "text", "except_id": "conn-123"},
    {"event": "send", "id": "conn-123", "data": "...", "opcode": "text"}
  ]
}
```

For errors:

```json
{
  "mode": "websocket_dispatch",
  "event": "error",
  "id": "conn-123",
  "error_class": "worker_runtime_error",
  "error": "uncaught exception"
}
```

## Command list

The command list should remain intentionally small:

- `send`
- `close`
- `join`
- `leave`
- `broadcast`
- `send_to`
- `set_meta`
- `clear_meta`

These already exist in phase 1 and should be reused.

## Suggested vhttpd internals

Introduce a dedicated dispatcher path instead of folding everything into the
current phase-1 websocket loop.

```v
fn (mut app App) dispatch_ws_event(envelope WsEventEnvelope) ![]WsCommand
fn (mut app App) execute_ws_commands(conn_id string, commands []WsCommand)
fn (mut app App) build_ws_envelope(kind string, state &WsConnState, ...) WsEventEnvelope
```

The websocket callbacks should become thin:

```v
fn websocket_on_message(...) {
    envelope := app.build_ws_envelope('message', ...)
    commands := app.dispatch_ws_event(envelope) or {
        // close or send error policy
        return
    }
    app.execute_ws_commands(conn_id, commands)
}
```

## Suggested php-worker internals

Add a new dispatch branch:

```php
if (($payload['mode'] ?? '') === 'websocket_dispatch') {
    return self::handleWebSocketDispatch($payload, $app);
}
```

That branch should:

1. load bootstrap
2. resolve app websocket handler
3. create a transient command collector
4. invoke the matching event callback
5. return collected commands

The collector can mimic the current `Connection` API, but instead of
writing frames directly to the worker transport, it appends commands to an array.

## PHP API direction

Phase 1 API:

- `$conn->send(...)`
- `$conn->join(...)`
- `$conn->broadcast(...)`

These methods can stay.

The implementation underneath changes:

- phase 1: direct command frames written immediately on the live worker connection
- phase 2: commands are collected and returned at the end of the event dispatch

That means most userland code should survive unchanged.

This is a major advantage of keeping the command vocabulary small and stable.

## VSlim impact

`VSlim\WebSocket\App` can remain the public entry point, but some assumptions should be softened:

- process-local connection ownership becomes legacy behavior
- `remember/forget/join/leave/broadcast` on `VSlim\WebSocket\App` are still useful for tests and single-worker mode
- production multi-worker websocket code should prefer connection-level commands

Longer term, `VSlim\WebSocket\App` should become explicitly event-driven rather than connection-owned.

## Stream implications

The same principle applies to stream mode:

- long-lived SSE / text streams should eventually be connection-hosted in `vhttpd`
- worker should emit stream commands or chunk decisions, not hold the stream socket forever

This should be a later phase, after websocket dispatch proves out.

## Rollout plan

### Step 1

Keep phase 1 and phase 2 side-by-side.

- current websocket mode remains available
- add a config flag or app capability flag to opt into `websocket_dispatch`

### Step 2

Implement message dispatch first.

- `open` and `message` dispatch
- command list execution
- simple `close`

### Step 3

Add `close` event dispatch with final snapshots.

### Step 4

Run both demos:

- phase 1 room demo
- phase 2 message-dispatch echo/chat demo

### Step 5

Only after phase 2 is stable, decide whether phase 1 remains as legacy mode or is deprecated.

## First MVP slice

The smallest useful phase-2 MVP is:

- text websocket only
- `open`, `message`, `close`
- commands:
  - `send`
  - `close`
  - `join`
  - `broadcast`
  - `set_meta`
- no binary frames
- no external cluster bus

If that works, we have already solved the core scaling problem:

- many connections can stay open in `vhttpd`
- only active events use PHP workers

That is the architectural win we want.
