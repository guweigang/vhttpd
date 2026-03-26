# Stream Phase 2 Implementation Plan

This document defines the next architectural step for `vhttpd` stream mode.

Today, long-lived stream responses still behave much closer to a
connection-hosted model:

- `vhttpd` opens a worker connection
- worker emits `start/chunk/error/end`
- the worker stays tied to that stream until completion

That model works, but it keeps worker occupancy proportional to stream
lifetime. For AI token streaming, SSE feeds, and long text streams, that is
the same scaling problem WebSocket phase 1 had.

WebSocket phase 2 already proved a better model:

- connection stays in `vhttpd`
- worker handles short-lived events
- worker count and connection count become decoupled

Stream phase 2 applies the same principle to HTTP streaming.

## Goals

- keep long-lived stream sockets in `vhttpd`
- make stream generation worker-driven but not worker-owned
- support SSE and text chunk streams first
- keep `VSlim\Stream\Response` and `VPhp\VHttpd\PhpWorker\StreamResponse` userland APIs stable where possible
- make AI token streaming scale without one worker per live client

## Non-goals

- replacing the existing stream mode immediately
- adding durable queues or message persistence
- multi-node stream fanout
- bidirectional transport semantics

## Current problem

In the current stream pipeline:

```text
client
  -> vhttpd
  -> php-worker
  -> app returns StreamResponse
  -> worker emits stream frames over one long-lived worker socket
  -> vhttpd forwards chunks until end
```

That means a long stream still occupies a worker for its full duration.

This is acceptable for MVP, but not for the model we want long-term.

## Target model

Stream phase 2 should move to a pull-style dispatch model:

```text
client
  -> vhttpd stream connection
  -> stream state lives in vhttpd
  -> vhttpd dispatches short-lived stream events to a worker
  -> worker returns stream commands/chunks
  -> vhttpd writes chunks to client
  -> repeat until end
```

The worker no longer owns the stream socket.

Current MVP note:

- `VPhp\VHttpd\PhpWorker\StreamApp::fromSequence(...)` can turn a finite chunk/event sequence into a replayable phase-2 stream.
- `VPhp\VHttpd\PhpWorker\StreamApp::fromStreamResponse(...)` can adapt a finite `VPhp\VSlim\Stream\Response` into the same `open / next / close` loop.
- `VPhp\VSlim\Stream\Factory::dispatchSse(...)`, `dispatchText(...)`, and `dispatchResponse(...)` are the preferred high-level builders for package users.
- This is intentionally aimed at synthetic or fully materializable streams first. Live upstream handles such as Ollama sockets still need a later phase-2 specific adapter.

## Why stream is different from websocket

WebSocket is message/event driven by the client.
HTTP streaming is usually producer-driven by the server.

That means phase 2 stream mode should likely be **pull-based**, not event-push duplex.

The most natural shape is:

- `stream.open`
- repeated `stream.next`
- optional `stream.close`

`vhttpd` drives those steps.

## Proposed stream lifecycle

### 1. Open

`vhttpd` receives a normal HTTP request.

Instead of binding the worker for the entire stream, it sends:

```json
{
  "mode": "stream",
  "strategy": "dispatch",
  "event": "open",
  "id": "req-123",
  "method": "GET",
  "path": "/ollama/sse",
  "query": {"prompt": "hello"},
  "headers": {"accept": "text/event-stream"},
  "body": "",
  "state": {}
}
```

Worker returns:

- stream type
- headers
- initial stream state token/snapshot
- optional first batch of chunks/events
- whether stream is done

### 2. Next

If stream is not done, `vhttpd` periodically or immediately dispatches:

```json
{
  "mode": "stream",
  "strategy": "dispatch",
  "event": "next",
  "id": "req-123",
  "state": {
    "...": "opaque worker state"
  }
}
```

Worker returns:

- updated state
- next batch of chunks/events
- done flag

### 3. Close

If client disconnects or stream completes, `vhttpd` may send:

```json
{
  "mode": "stream",
  "strategy": "dispatch",
  "event": "close",
  "id": "req-123",
  "state": {...},
  "reason": "client_disconnect"
}
```

This allows cleanup in userland if needed.

## Core design decision: state token

Phase 2 stream mode needs one of these:

1. opaque state snapshot returned by worker and sent back on every `next`
2. worker-side stream id registry
3. `vhttpd`-side stream state machine with explicit commands

I recommend option 1 first:

- worker returns a serializable state payload
- `vhttpd` stores it per request
- each `next` call sends it back

Why:

- easiest to reason about
- avoids long-lived worker memory ownership
- works across any worker process
- fits the same stateless worker philosophy as websocket phase 2

## Stream request/response shapes

### Dispatch request

```json
{
  "mode": "stream",
  "strategy": "dispatch",
  "event": "next",
  "id": "req-123",
  "state": {
    "cursor": 12,
    "upstream": {
      "kind": "ollama_ndjson",
      "buffer": ""
    }
  }
}
```

### Dispatch response

```json
{
  "mode": "stream",
  "strategy": "dispatch",
  "event": "result",
  "id": "req-123",
  "stream_type": "sse",
  "content_type": "text/event-stream",
  "headers": {
    "cache-control": "no-cache"
  },
  "state": {
    "cursor": 13
  },
  "chunks": [
    {
      "event": "chunk",
      "data": "token text"
    }
  ],
  "done": false
}
```

For SSE, each chunk can carry:

- `event`
- `id`
- `data`
- `retry`

For text streams, each chunk can carry:

- `data`

## Suggested V data structures

```v
struct StreamDispatchRequest {
    mode         string
    event        string // open|next|close
    id           string
    method       string
    path         string
    query        map[string]string
    headers      map[string]string
    body         string
    remote_addr  string
    request_id   string
    trace_id     string
    state        map[string]string
    reason       string
}

struct StreamDispatchChunk {
    event string
    id    string
    data  string
    retry int
}

struct StreamDispatchResponse {
    mode         string
    event        string
    id           string
    stream_type  string
    content_type string
    headers      map[string]string
    state        map[string]string
    chunks       []StreamDispatchChunk
    done         bool
    error        string
    error_class  string
}
```

For the MVP, `state` can stay `map[string]string`.
If that becomes too tight, move to `map[string]json.Any` later.

## vhttpd responsibilities

`vhttpd` should own:

- live client stream connection
- response headers / content type
- per-request dispatch state
- client disconnect detection
- write loop
- pacing / backoff for `next`

New helpers likely needed:

```v
fn dispatch_stream(mut app App, req StreamDispatchRequest) !StreamDispatchResponse
fn stream_open(...)
fn stream_next(...)
fn stream_close(...)
```

## php-worker responsibilities

Add a new branch:

```php
if (($req['mode'] ?? '') === 'stream' && ($req['strategy'] ?? '') === 'dispatch') {
    return $this->handleStream($req);
}
```

That branch should:

1. load app
2. resolve a stream-dispatch-capable handler
3. call open/next/close
4. return state + chunk batch

## PHP API strategy

There are two reasonable options.

### Option A: add new dispatch-specific stream app

Example:

```php
$stream = new VPhp\VHttpd\PhpWorker\StreamApp(
    open: function (array $req): array { ... },
    next: function (array $state): array { ... },
    close: function (array $state): void { ... },
);
```

Pros:

- explicit phase-2 shape
- does not overload existing `StreamResponse`

Cons:

- new userland API

### Option B: keep `StreamResponse`, but make some factories phase-2 aware

This is more attractive long-term, but trickier immediately.

For MVP, I recommend **Option A first**.

Once it is stable, we can layer `StreamResponse` or `VSlim\Stream\Factory` on top.

## VSlim implications

VSlim already has:

- `VSlim\Stream\Response`
- `VSlim\Stream\Factory`

But these are still phase-1 friendly.

For stream phase 2, VSlim likely needs a parallel API first, for example:

- `VSlim\Stream\Dispatch\App`
- `VSlim\Stream\Dispatch\OllamaSession`

or a compact helper:

```php
return VSlim\Stream\Factory::dispatch_sse(...);
```

I would still avoid forcing this into the existing `Response` abstraction too early.

## Best first use case

The strongest first target is:

- Ollama SSE/text streaming

Why:

- already implemented in phase 1
- clearly long-lived
- usually token-by-token
- easy to compare old and new behavior

The first phase-2 stream MVP does not need to support every stream source.

It only needs to prove:

- one long SSE connection no longer occupies one worker
- one worker can serve multiple concurrent stream clients by handling short-lived `next` calls

## Scheduling model for `next`

There are two choices:

### Immediate pull loop

After each response, `vhttpd` immediately asks for `next` again until:

- worker returns no chunks and no done
- or a small backoff is needed

### Timed polling

`vhttpd` schedules `next` with a small delay.

For MVP, I recommend:

- immediate pull when chunks were returned
- short backoff when chunk batch is empty and stream is not done

That keeps implementation simple while avoiding a busy loop.

## Failure model

If `open` fails:

- return normal HTTP error response

If `next` fails:

- emit stream error to event log
- terminate client stream

If client disconnects:

- best-effort `close` dispatch
- clean local stream state

## Rollout plan

### Step 1

Add `mode=stream` plus `strategy=dispatch` to php-worker and vhttpd transport.

### Step 2

Implement one internal demo source:

- synthetic SSE counter stream

### Step 3

Implement Ollama phase-2 adapter.

### Step 4

Expose a VSlim example:

- `stream_app.php`

### Step 5

Compare:

- phase-1 stream mode
- phase-2 stream dispatch mode

especially under:

- one worker
- multiple simultaneous SSE clients

## First MVP slice

The minimum useful stream phase-2 MVP is:

- SSE only
- `open`, `next`, `close`
- string-keyed state map
- one simple synthetic stream app
- one Ollama-backed demo after the synthetic path works

If that works, then the same decoupling principle is proven for stream mode too:

- long-lived connections stay in `vhttpd`
- PHP workers are used for short-lived work, not connection occupancy
