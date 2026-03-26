# Stream Runtime Phases

This page summarizes the current stream evolution in `vhttpd`.

## Phase 1: connection-hosted stream

The original stream model looks like this:

```text
client
  -> vhttpd
  -> php-worker
  -> app returns StreamResponse
  -> worker emits start/chunk/error/end
  -> same worker stays occupied until stream end
```

Characteristics:

- easy to understand
- works for text and SSE
- good MVP for finite or short-lived streams
- worker occupancy is proportional to stream lifetime

This mode is still valid, but it does not scale well for long token streams.

## Phase 2: stream + dispatch strategy

Phase 2 decouples the downstream client connection from the worker.

`vhttpd` keeps ownership of the client socket and drives:

- `open`
- repeated `next`
- optional `close`

The worker only handles short-lived dispatch calls and returns:

- stream metadata
- next batch of chunks/events
- serializable `state`
- `done`

Characteristics:

- downstream stream does not lock a worker
- any worker can handle the next dispatch step
- good for synthetic SSE/text streams and finite replayable sequences
- still not enough for live upstream sockets opened inside PHP

Typical builders:

- `VPhp\VHttpd\PhpWorker\StreamApp`
- `VPhp\VSlim\Stream\Factory::dispatchText(...)`
- `VPhp\VSlim\Stream\Factory::dispatchSse(...)`
- `VPhp\VSlim\Stream\Factory::dispatchResponse(...)`

## Phase 3: stream + upstream_plan strategy

Phase 3 extends the same decoupling principle to the upstream side.

Instead of letting PHP open and hold a live upstream stream, the worker returns
an `Upstream\Plan`, and `vhttpd` executes it itself.

```text
client
  -> vhttpd
  -> php-worker returns UpstreamPlan
  -> vhttpd opens upstream stream
  -> vhttpd decodes/mapps upstream chunks
  -> vhttpd writes downstream text/SSE
```

Characteristics:

- downstream client stream does not lock a worker
- upstream live stream also does not lock a worker
- `vhttpd` becomes the owner of both stream edges
- worker becomes a short-lived planner

Current MVP supports:

- `transport = http`
- `codec = ndjson`
- `mapper = ndjson_text_field`
- `mapper = ndjson_sse_field`
- deterministic `fixture_path`
- live upstream HTTP streaming via `net.http`

## Practical decision rule

Use phase 1 when:

- you already have a simple `StreamResponse`
- the stream is short-lived
- you want the simplest runtime path

Use phase 2 when:

- the stream is replayable or synthetic
- you can model progress as serializable `state`
- you want downstream streams to stop occupying workers

Use phase 3 when:

- the upstream source is itself a live stream
- PHP should not keep an upstream socket open
- `vhttpd` should own both upstream and downstream stream lifecycles

## Current MVP conclusion

Today the runtime story is:

- WebSocket phase 2 is proven
- Stream phase 2 is proven for synthetic/replayable streams
- Stream phase 3 is proven for NDJSON-based upstream plans such as Ollama

That means `vhttpd` already has a consistent direction:

- connections belong in `vhttpd`
- workers should be short-lived planners/handlers
- transport contracts should be explicit and serializable
