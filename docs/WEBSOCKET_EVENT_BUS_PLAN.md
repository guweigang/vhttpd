# vhttpd WebSocket Event Bus Plan (Single Node)

## Goal

Build the next WebSocket phase around `vhttpd` itself:

```text
browser websocket client
  -> vhttpd owns socket lifecycle
  -> php-worker handles business callbacks
  -> vhttpd hub owns local connection registry + room fanout
```

The goal of this phase is not cluster/distributed messaging yet.
It is to make multiple PHP workers behave like one local realtime node.

## Why this phase is needed

The current MVP already supports:

- websocket upgrade in `vhttpd`
- `mode=websocket` worker frames
- PHP userland callbacks

But room state still lives inside each PHP worker process.
That means:

- single worker: room broadcast works, but concurrency is poor
- multiple workers: concurrency works, but rooms are isolated per worker

So the next step is to move **connection ownership and room membership** into `vhttpd`.

## Reuse from vlib

### Reuse directly

#### `net.websocket`

Keep using `net.websocket` for:

- handshake
- frame parsing
- ping/pong
- close lifecycle

This remains the protocol engine.
`vhttpd` should not reimplement RFC6455.

#### `eventbus`

`eventbus` is a reasonable fit for **in-process notifications** such as:

- connection attached
- connection detached
- room joined
- room left
- room publish

It is useful as a decoupling helper, but not as the source of truth.

Why not use it as the whole hub:

- it does not maintain room membership for us
- it does not model connection ownership
- it does not provide backpressure or delivery policy

So `eventbus` is optional support, not the registry itself.

### Reuse later, not as the core

#### `sync.pool`

`sync.pool` is a parallel task worker pool.
It is good for:

- fanout batch work
- expensive encode/decode jobs
- temporary payload processing

It is **not** the right primitive for the websocket hub itself.
The hub is a long-lived registry and event loop, not a batch processor.

#### `pool`

The `pool` module is about reusable connection-like resources.
It does not map well to websocket room routing and broadcast state.

## Core design

### High-level model

`vhttpd` becomes the local websocket hub.

PHP worker no longer owns the room graph.
Instead, worker code sends control intents back to `vhttpd`:

- join a room
- leave a room
- broadcast to a room
- send to a specific connection

`vhttpd` then fans out to local websocket clients, even when they belong to different PHP workers.

## Ownership split

### `vhttpd`

Owns:

- websocket TCP connections
- connection id registry
- room membership
- worker routing for each live connection
- local fanout

### `php-worker`

Owns:

- app callbacks
- auth/business logic
- message shaping
- deciding which room or connection to target

### `VSlim\WebSocket\App`

Owns:

- developer-facing API
- convenient wrappers over websocket control frames

## Source of truth

The source of truth should move to `vhttpd`:

- `conn_id -> connection handle`
- `conn_id -> owning worker socket`
- `room -> set of conn_id`
- `conn_id -> set of room`

That state should not be duplicated as authoritative state in PHP workers.

## Recommended primitives

### Must-have

- `shared` maps guarded by `sync.RwMutex` or normal `lock` blocks
- `chan HubEvent` for serialized hub mutations
- `net.websocket` for connection protocol handling

### Nice-to-have

- `eventbus` for secondary internal notifications
- `sync.pool` only after profiling shows fanout/encoding hot spots

## Hub data structures

Suggested first pass:

```v
struct HubConn {
    id            string
    worker_socket string
mut:
    client        &websocket.Client
    request_id    string
    trace_id      string
    path          string
}

struct HubState {
mut:
    conns         map[string]&HubConn
    room_members  map[string]map[string]bool
    conn_rooms    map[string]map[string]bool
}

enum HubEventKind {
    attach
    detach
    join
    leave
    send
    broadcast
}

struct HubEvent {
    kind        HubEventKind
    conn_id     string
    room        string
    except_id   string
    worker      string
    data        string
    opcode      string
    close_code  int
    close_reason string
}
```

Implementation detail:

- prefer `map[string]bool` sets over `[]string` for membership updates
- keep mutation inside one hub loop to reduce locking complexity

## Worker protocol extension

Keep the existing `mode=websocket` frame channel.
Add new worker -> `vhttpd` control events.

### worker -> vhttpd control frames

#### Join

```json
{
  "mode": "websocket",
  "event": "join",
  "id": "conn-123",
  "room": "lobby"
}
```

#### Leave

```json
{
  "mode": "websocket",
  "event": "leave",
  "id": "conn-123",
  "room": "lobby"
}
```

#### Broadcast

```json
{
  "mode": "websocket",
  "event": "broadcast",
  "id": "conn-123",
  "room": "lobby",
  "data": "{\"type\":\"chat\",\"text\":\"hello\"}",
  "opcode": "text",
  "except_id": "conn-123"
}
```

#### Send to one connection

```json
{
  "mode": "websocket",
  "event": "send_to",
  "id": "conn-123",
  "target_id": "conn-456",
  "data": "{\"type\":\"dm\",\"text\":\"hi\"}",
  "opcode": "text"
}
```

### vhttpd -> worker frames

Keep the current application-facing events:

- `open`
- `message`
- `close`

That means this phase does **not** require changing PHP callback signatures.
The main change is that some outgoing actions are now interpreted as hub commands, not only direct socket writes.

## First implementation strategy

### Step 1. Introduce a local websocket hub in `vhttpd`

Add a singleton-like hub inside `App`:

- event channel
- connection registry
- room registry

This should be process-local, not global static state.

### Step 2. Register each connection on successful upgrade

When websocket open succeeds:

- create `HubConn`
- attach it to hub state
- record its owning worker socket

On close:

- emit `detach`
- remove the connection from all rooms

### Step 3. Extend worker reply handling

Today `worker_websocket_message_cb()` handles:

- `send`
- `close`
- `error`
- `done`

Extend it to also handle:

- `join`
- `leave`
- `broadcast`
- `send_to`

Those four should mutate hub state or fan out immediately through the hub.

### Step 4. Keep `send` working as a direct response primitive

`send` should remain a direct "write back to this connection" command.
That keeps existing echo-style apps working unchanged.

### Step 5. Add PHP helper methods that map to control frames

At package level:

- `Connection::join(string $room): void`
- `Connection::leave(string $room): void`
- `Connection::broadcast(string $room, string $data, string $opcode = 'text', string $exceptId = ''): void`
- `Connection::sendTo(string $targetId, string $data, string $opcode = 'text'): void`

At VSlim extension level later:

- `VSlim\WebSocket\App` can wrap those into convenient room helpers

## Why this avoids duplicate wheels

This phase does not reimplement:

- websocket protocol
- generic pub/sub runtime
- generic worker pool framework

It adds only the missing application-specific layer:

- local connection registry
- room membership
- fanout routing

That is the part neither `net.websocket` nor `eventbus` gives us.

## Delivery semantics for phase 1

Keep semantics intentionally simple:

- single node only
- best effort local delivery
- no message persistence
- no replay
- no ordering guarantees across rooms
- in-room iteration order is unspecified

This is enough for chat, presence, live dashboards, and collaborative UI MVPs.

## Failure behavior

### On unknown room

- `broadcast(room=missing)` should no-op

### On unknown target connection

- `send_to(target=missing)` should no-op

### On stale connection in room registry

- remove it lazily when encountered

### On worker death

- all connections owned by that worker should be detached from the hub

## API direction for PHP/VSlim

### Package side

The package-level `Connection` should gain hub-oriented methods.

That keeps userland code simple:

```php
$conn->join('lobby');
$conn->broadcast('lobby', json_encode(['user' => 'alice', 'text' => 'hi']), exceptId: $conn->id());
```

### VSlim side

`VSlim\WebSocket\App` should stop treating rooms as authoritative in-process memory for multi-worker deployments.

Its long-term role should be:

- app callback registry
- route dispatch
- sugar over `Connection`

Not the cross-worker room source of truth.

## Implementation order

1. Add hub state and event channel in `vhttpd`
2. Register/detach connections in websocket bridge lifecycle
3. Extend worker websocket reply parser for `join/leave/broadcast/send_to`
4. Add package helper methods on `Connection`
5. Migrate the websocket room demo to use connection-level hub commands
6. Add regression test: two different workers, same room, both receive broadcasts

## Out of scope for this phase

- multi-node cluster
- Redis/NATS integration
- room sharding
- persistence
- presence snapshots
- binary frame routing
- durable subscriptions

## Next phase after this one

Once single-node cross-worker fanout is stable, the next clean step is:

- optional external bus adapter for multi-node fanout

That keeps the architecture layered:

```text
single node:
  vhttpd local hub

multi node:
  vhttpd local hub
    + external bus adapter
```

If you want to go further and decouple live websocket connections from worker occupancy entirely, see:

- [`/Users/guweigang/Source/vhttpd/docs/WEBSOCKET_MESSAGE_DISPATCH_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/WEBSOCKET_MESSAGE_DISPATCH_PLAN.md)
