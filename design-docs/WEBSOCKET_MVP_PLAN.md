# vhttpd WebSocket MVP Plan

## Goal

Keep `vhttpd` focused on transport/runtime concerns:

```text
HTTP / WebSocket protocol
  -> vhttpd
  -> php-worker transport
  -> PHP app
```

The first WebSocket version should:

- reuse V's built-in [`net.websocket`](https://modules.vlang.io/net.websocket.html)
- avoid reimplementing handshake, frame parsing, ping/pong, and close handling
- fit the existing `vhttpd -> php-worker` architecture
- keep PHP userland focused on business messages, not protocol internals

For the next single-node cross-worker phase, see:

- [`/Users/guweigang/Source/vhttpd/docs/WEBSOCKET_EVENT_BUS_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/WEBSOCKET_EVENT_BUS_PLAN.md)

## Key findings

### 1. `veb.Context` already exposes the TCP connection

`veb.Context` contains:

- `conn &net.TcpConn`
- `takeover_conn()`

This gives `vhttpd` a safe escape hatch for upgraded connections:

- detect `Upgrade: websocket`
- call `ctx.takeover_conn()`
- hand `ctx.conn` to `net.websocket`

### 2. `net.websocket` already supports server-side handshake on an existing connection

`vlib/net/websocket/websocket_server.v` exposes:

- `websocket.Server`
- `Server.handle_handshake(mut conn net.TcpConn, key string) !&ServerClient`

This is the most important reuse point for `vhttpd`.

It means `vhttpd` does not need to run a second listener or implement RFC6455 itself.

### 3. Current worker contract is request/response or request/stream, not duplex

Today the worker protocol supports:

- one-shot JSON response
- server-driven stream frames

WebSocket needs a new transport shape:

- `vhttpd -> worker`: open + message + close events
- `worker -> vhttpd`: send + close commands

So the WebSocket MVP should extend the worker frame contract, not try to fake WebSocket as SSE.

## Recommended MVP scope

### In scope

- HTTP upgrade handling in `vhttpd`
- text-frame WebSocket messages
- close events
- worker-level duplex frame channel
- minimal PHP handler API

### Out of scope for MVP

- binary frames
- permessage-deflate
- subprotocol negotiation
- room/broadcast abstractions
- cross-worker connection routing
- cluster/distributed fanout

## Architecture

```text
Browser
  -> HTTP GET with Upgrade: websocket
  -> vhttpd route/proxy branch
  -> ctx.takeover_conn()
  -> net.websocket handles handshake + socket loop
  -> websocket events bridged to php-worker over unix socket
  -> PHP app decides send/close actions
  -> vhttpd writes back via net.websocket client object
```

## Upgrade entry point

The lowest-risk entry point is inside the worker proxy path:

- current HTTP proxy entry: `proxy_worker_response(...)`
- new branch before normal request encoding:
  - detect websocket upgrade headers
  - switch to `proxy_worker_websocket(...)`

This keeps:

- static files unchanged
- `/events/stream` unchanged
- existing HTTP worker logic unchanged

## WebSocket request detection

Treat a request as WebSocket only when all are true:

- `method == GET`
- header `Upgrade: websocket`
- header `Connection` contains `Upgrade`
- header `Sec-WebSocket-Key` is present

If validation fails, return normal HTTP `400`/`426`.

## Worker frame protocol

Use the same framing layer as today:

```text
[4-byte big-endian length][json payload]
```

### vhttpd -> worker frames

#### Open

```json
{
  "mode": "websocket",
  "event": "open",
  "id": "trace-id-or-conn-id",
  "path": "/ws/chat",
  "query": { "room": "general" },
  "headers": { "host": "127.0.0.1:19881" },
  "remote_addr": "127.0.0.1",
  "request_id": "req-123",
  "trace_id": "req-123"
}
```

#### Message

```json
{
  "mode": "websocket",
  "event": "message",
  "id": "trace-id-or-conn-id",
  "opcode": "text",
  "data": "hello"
}
```

#### Close

```json
{
  "mode": "websocket",
  "event": "close",
  "id": "trace-id-or-conn-id",
  "code": 1000,
  "reason": "client closed"
}
```

### worker -> vhttpd frames

#### Accept

Sent after worker receives `open`.

```json
{
  "mode": "websocket",
  "event": "accept",
  "id": "trace-id-or-conn-id"
}
```

This lets PHP reject or accept a connection before message processing starts.

#### Send

```json
{
  "mode": "websocket",
  "event": "send",
  "id": "trace-id-or-conn-id",
  "opcode": "text",
  "data": "hello from php"
}
```

#### Close

```json
{
  "mode": "websocket",
  "event": "close",
  "id": "trace-id-or-conn-id",
  "code": 1000,
  "reason": "done"
}
```

#### Error

```json
{
  "mode": "websocket",
  "event": "error",
  "id": "trace-id-or-conn-id",
  "error_class": "worker_runtime_error",
  "error": "message"
}
```

## PHP handler shape

The PHP side should not work with raw RFC6455 details.

The smallest useful contract is:

```php
return new VPhp\VSlim\WebSocket\App(
    onOpen: function (Connection $conn, array $open): void {
        $conn->send('connected');
    },
    onMessage: function (Connection $conn, string $message): void {
        $conn->send('echo: ' . $message);
    },
    onClose: function (Connection $conn, int $code, string $reason): void {
    },
);
```

Alternative callable contract:

```php
return function (array $frame, VPhp\VHttpd\PhpWorker\WebSocket\Connection $conn): void {
    if (($frame['event'] ?? '') === 'open') {
        $conn->accept();
        return;
    }
    if (($frame['event'] ?? '') === 'message') {
        $conn->send('echo: ' . ($frame['data'] ?? ''));
    }
};
```

For MVP, `Connection` should support only:

- `accept(): void`
- `send(string $data): void`
- `close(int $code = 1000, string $reason = ''): void`
- `id(): string`

## Why not return a PSR-7 response?

Because after upgrade there is no longer a normal HTTP response lifecycle.

This is closer to:

- connection session
- duplex event loop
- command channel

So WebSocket should be a distinct worker contract, not a special `Response`.

## vhttpd-side lifecycle

### On incoming HTTP upgrade request

1. validate headers
2. connect to selected PHP worker socket
3. send worker `open` frame
4. wait for `accept` or `close`
5. if accepted:
   - call `ctx.takeover_conn()`
   - create `websocket.Server`
   - call `handle_handshake(mut ctx.conn, key)`
   - wire websocket callbacks

### On WebSocket message from client

1. receive `Message` from `net.websocket`
2. if text frame:
   - send worker `message` frame
3. read worker output frames until:
   - zero or more `send`
   - optional `close`

### On close

1. send worker `close`
2. close unix socket to worker
3. let `net.websocket` complete socket shutdown

## First implementation constraints

To reduce risk, MVP should use:

- one unix socket worker connection per websocket client connection
- one PHP handler instance per accepted websocket connection
- synchronous message roundtrip per received text message

This is intentionally simple:

- easy to reason about
- easy to test
- matches current worker transport shape

It can be optimized later.

## Test plan

### V-side integration tests

- upgrade request rejected without valid websocket headers
- successful upgrade with echo app
- worker can send text frames back
- worker-triggered close propagates to client
- client-triggered close reaches worker

### PHP worker tests

- bootstrap returns websocket app object
- `open -> accept`
- `message -> send`
- `close` frame handling
- invalid websocket handler returns contract error

## Suggested implementation order

1. Add websocket frame structs to `vhttpd`
2. Add `proxy_worker_websocket(...)` in `vhttpd`
3. Add PHP worker websocket dispatcher and connection helper
4. Add minimal PHP echo demo
5. Add end-to-end test using a websocket client

## Non-goals for the first patch

Do not block MVP on:

- room state
- pub/sub
- Redis fanout
- auth framework integration
- binary payload codecs

The first deliverable is simply:

> `vhttpd` can accept a WebSocket upgrade and bridge text messages to a PHP worker using V's built-in `net.websocket`.
