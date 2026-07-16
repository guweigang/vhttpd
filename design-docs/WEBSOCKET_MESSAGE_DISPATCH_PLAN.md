# vhttpd WebSocket Message-Dispatch Plan

## Goal

Define the next WebSocket architecture after the single-node event bus phase:

```text
browser websocket client
  -> vhttpd owns all live websocket connections
  -> vhttpd owns room/presence/session metadata
  -> each websocket event is dispatched to an available php-worker
  -> worker returns commands, but does not stay attached to the socket
```

This is the architecture that can eventually break the current rule:

> one websocket connection occupies one worker

## Naming

Use two explicit mode names:

- `connection-hosted mode`
  the current model, where one live websocket connection stays bound to one worker
- `message-dispatch mode`
  the future model, where workers process events, not own connections

The current codebase should continue to treat `connection-hosted mode` as the default until `message-dispatch mode` is designed, implemented, and validated.

## Why this direction is attractive

### What it improves

- websocket connection count becomes less coupled to worker count
- PHP workers are used for business logic only when an event arrives
- `vhttpd` becomes the stable realtime gateway layer
- room fanout, presence, and local routing become more coherent
- future multi-node support becomes easier to layer on top

### What it changes

- worker-local connection state becomes unreliable
- open/message/close for the same websocket may hit different workers
- `VSlim\WebSocket\App` can no longer assume in-process memory is connection-local truth

So this is a good long-term direction, but it is not a small refactor.

## Core idea

In `message-dispatch mode`, websocket sockets stay fully owned by `vhttpd`.

When an event happens:

- `open`
- `message`
- `close`

`vhttpd` packages the event and dispatches it to any available worker.
The worker returns a set of commands such as:

- accept
- send
- close
- join
- leave
- broadcast
- set metadata

Then `vhttpd` executes those commands against its own local hub state and socket registry.

Workers do not remain attached to the connection after the event finishes.

## Contrast with the current model

### Today: connection-hosted mode

```text
conn A -> worker 1
conn B -> worker 2
conn C -> worker 3
```

Worker 1 remains busy as long as `conn A` lives.

### Future: message-dispatch mode

```text
conn A lives in vhttpd
conn B lives in vhttpd
conn C lives in vhttpd

message from A -> any idle worker
message from B -> any idle worker
close from C   -> any idle worker
```

That is the key scalability win.

## Source of truth

In this model, the source of truth must live in `vhttpd`, not PHP workers.

That includes:

- connection registry
- room membership
- presence / user metadata
- auth/session tags attached to a connection
- routing information for broadcasts and direct sends

Any PHP-visible state should be treated as a snapshot or helper view, not authoritative storage.

## Required state in `vhttpd`

Suggested categories:

- `conn_id -> websocket client`
- `conn_id -> metadata`
- `conn_id -> joined rooms`
- `room -> conn_ids`
- `conn_id -> authenticated user id`
- `conn_id -> arbitrary app-scoped attributes`

The metadata store should be explicit because workers cannot rely on connection-local memory anymore.

## Worker contract change

The current `mode=websocket` frame stream is stateful across a live socket session.
`message-dispatch mode` should move to a stateless per-event request/command shape.

### vhttpd -> worker request

Example:

```json
{
  "mode": "websocket_dispatch",
  "event": "message",
  "id": "conn-123",
  "path": "/ws",
  "query": { "room": "lobby" },
  "headers": { "host": "127.0.0.1:19891" },
  "metadata": {
    "user_id": "u-42",
    "rooms": ["lobby"],
    "attrs": {
      "role": "member"
    }
  },
  "opcode": "text",
  "data": "{\"text\":\"hello\"}"
}
```

### worker -> vhttpd response

Instead of an open-ended duplex loop, the worker returns a command list:

```json
{
  "mode": "websocket_dispatch",
  "id": "conn-123",
  "commands": [
    { "event": "send", "data": "{\"type\":\"self_ack\"}" },
    { "event": "broadcast", "room": "lobby", "data": "{\"type\":\"chat\",\"text\":\"hello\"}", "except_id": "conn-123" },
    { "event": "set_metadata", "attrs": { "last_seen_at": 1770000000 } }
  ]
}
```

This is easier to scale because one worker invocation becomes one finite task.

## Why command lists fit better

Command lists make worker execution bounded:

- one request in
- one response out

That is much easier to:

- route through a pool
- timeout safely
- retry cautiously
- meter and observe

It also removes the need for a worker to hold the unix socket open for the whole websocket session.

## Required command set

Minimum likely commands:

- `accept`
- `send`
- `close`
- `join`
- `leave`
- `broadcast`
- `send_to`
- `set_metadata`
- `clear_metadata`

Optional later:

- `schedule_close`
- `presence_update`
- `kick_room`
- `replace_rooms`

## Metadata model

This is the hardest part, and it needs to be explicit.

Workers will often need context such as:

- authenticated user
- joined rooms
- request-scoped claims
- custom app session flags

That means `vhttpd` needs a metadata store per connection.

Recommended split:

- reserved fields owned by `vhttpd`
  - connection id
  - path
  - rooms
  - connected_at
  - remote_addr
- app metadata owned by worker commands
  - `attrs: map[string]string`

This avoids mixing transport data and app data.

## API implications for PHP

### Current-style callbacks need reinterpretation

This API shape can remain:

```php
$ws->on_open(...)
$ws->on_message(...)
$ws->on_close(...)
```

But the semantics change:

- callbacks must be treated as stateless handlers
- any required durable connection state must come from frame metadata
- any state changes must be written back through returned commands

### Connection object should become a command builder

In `message-dispatch mode`, `Connection` is no longer a live bound socket proxy.
It should behave more like:

- a command collector for the current event
- a convenience facade over the returned command list

For example:

```php
$conn->join('lobby');
$conn->set('user_id', 'u-42');
$conn->broadcast('lobby', $payload, exceptId: $conn->id());
```

These methods would enqueue commands in the current worker response, not immediately write to a long-lived connection channel.

## API implications for VSlim

### What should remain

- route registration
- websocket callback ergonomics
- request/frame parsing helpers

### What should weaken or disappear as source of truth

- in-process room registries
- in-process remembered connection objects
- any expectation that `on_open` and `on_message` share the same worker memory

`VSlim\WebSocket\App` can still expose convenience helpers, but they should become wrappers over the command model, not local room state.

## Scheduling model

This architecture works best if websocket events are treated like ordinary short jobs.

Likely flow:

1. websocket event arrives in `vhttpd`
2. `vhttpd` snapshots metadata
3. `vhttpd` sends one dispatch request to an idle worker
4. worker returns commands
5. `vhttpd` applies commands
6. worker is immediately free again

That means worker pools can be sized for message throughput, not connection count.

## Backpressure and safety

This model is more scalable, but it also needs stricter guardrails.

### Worker timeout

If a worker takes too long to process one websocket event:

- `vhttpd` should fail that event
- optionally send an error to the connection
- optionally close the connection for repeated violations

### Command validation

`vhttpd` must validate worker-returned commands:

- unknown room names: ignore or reject
- unknown target ids: ignore
- oversized payloads: reject
- invalid opcodes: reject

### Ordering

Ordering is subtle.
At minimum, events for the same connection should be serialized in `vhttpd`.

Otherwise:

- two messages from the same client could be handled out of order by different workers

Recommended first rule:

- per-connection event queue in `vhttpd`
- one in-flight worker dispatch per connection

This preserves per-connection order while still letting different connections use different workers.

## Relationship to phase 1 event bus

The single-node event bus phase is not wasted work.
It is the direct foundation for `message-dispatch mode`.

Phase 1 gives us:

- local hub
- room registry
- local fanout
- connection metadata ownership in `vhttpd`

Phase 2 changes only the worker interaction pattern:

- from long-lived duplex session
- to short-lived per-event dispatch

So phase 1 is still the right next step.

## Migration path

Recommended sequence:

1. finish single-node local hub and cross-worker room fanout
2. move more room/presence state into `vhttpd`
3. add per-connection metadata store
4. prototype stateless event dispatch alongside the current mode
5. support both modes behind explicit configuration
6. validate VSlim API semantics in dispatch mode
7. only then consider making dispatch mode the default

## Recommended config model

Do not silently change behavior.
Use an explicit runtime knob, for example:

```toml
[websocket]
mode = "connection_hosted"
```

Later:

```toml
[websocket]
mode = "message_dispatch"
```

That keeps rollout safe.

## Risks

The biggest risks are semantic, not protocol-level:

- breaking assumptions about per-connection worker memory
- hidden ordering bugs
- metadata synchronization bugs
- subtle auth/session bugs when state moves into `vhttpd`

So the design is promising, but it needs a disciplined migration.

## Recommendation

This is the right **phase 2 direction**, not the right immediate implementation target.

Immediate priority should still be:

- complete the single-node event bus
- validate cross-worker room broadcast
- harden local hub state and lifecycle

Then build `message-dispatch mode` on top of that foundation.
