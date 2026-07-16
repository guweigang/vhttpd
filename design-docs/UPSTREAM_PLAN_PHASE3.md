# Upstream Plan (Phase 3)

This document defines the next step after the stream dispatch strategy.

Phase 2 already decouples the **client stream connection** from the PHP worker:

- client connection stays in `vhttpd`
- worker only handles short-lived `open / next / close`

That is enough for synthetic streams and replayable finite sequences.

It is **not** enough for live upstream streams such as Ollama, because the PHP
worker would still have to keep an upstream socket resource open.

## Problem

If a PHP worker opens an Ollama stream itself:

- it owns a live upstream socket
- that socket is not serializable into `state`
- a later `next` call might hit a different worker

So the worker would still be effectively locked by the upstream stream.

## Direction

The next architecture step is:

- PHP builds a generic `Upstream\Plan`
- `vhttpd` owns the upstream connection
- `vhttpd` decodes upstream chunks
- `vhttpd` maps upstream chunks into downstream SSE/text output

That keeps both sides decoupled:

- browser/client connection stays in `vhttpd`
- upstream AI stream also stays in `vhttpd`
- PHP worker becomes a short-lived planner

## Plan object

Package-side class:

- `VPhp\VHttpd\Upstream\Plan`

Current purpose:

- describe a generic upstream stream request
- stay transport-oriented, not provider-specific
- let Ollama be the first adapter, not a special case in `vhttpd`

Current fields include:

- `transport`
- `url`
- `method`
- `request_headers`
- `body`
- `codec`
- `mapper`
- `output_stream_type`
- `output_content_type`
- `response_headers`
- `fixture_path`
- `name`
- `meta`

Current MVP schema:

```json
{
  "transport": "http",
  "url": "http://127.0.0.1:11434/api/chat",
  "method": "POST",
  "request_headers": {
    "content-type": "application/json",
    "accept": "application/x-ndjson"
  },
  "body": "{\"model\":\"...\",\"stream\":true,\"messages\":[...]}",
  "codec": "ndjson",
  "mapper": "ndjson_text_field",
  "output_stream_type": "text",
  "output_content_type": "text/plain; charset=utf-8",
  "response_headers": {
    "x-ollama-model": "qwen2.5:7b-instruct"
  },
  "fixture_path": "",
  "name": "ollama_chat",
  "meta": {
    "field_path": "message.content",
    "fallback_field_path": "response",
    "sse_event": "token"
  }
}
```

Field notes:

- `transport`
  - current MVP only supports `http`
- `codec`
  - current MVP only supports `ndjson`
- `mapper`
  - current MVP supports `ndjson_text_field` and `ndjson_sse_field`
- `meta.field_path`
  - primary field to read from each decoded NDJSON row
- `meta.fallback_field_path`
  - optional fallback field when the primary field is empty
- `meta.sse_event`
  - event name used when output mode is SSE
- `fixture_path`
  - when non-empty, `vhttpd` reads a local deterministic fixture instead of opening a live upstream connection

## Ollama as first adapter

Package-side helper entrypoints now exist:

- `VPhp\VSlim\Stream\Factory::ollamaUpstreamTextPlan(...)`
- `VPhp\VSlim\Stream\Factory::ollamaUpstreamSsePlan(...)`
- `VPhp\VSlim\Stream\Factory::ollamaUpstreamPlan(...)`

These now feed a real phase-3 executor in `vhttpd`.

Current MVP supports:

- `transport = http`
- `codec = ndjson`
- `mapper = ndjson_text_field`
- `mapper = ndjson_sse_field`
- `meta.field_path = message.content`
- `meta.fallback_field_path = response`
- `meta.sse_event = token`
- local `fixture_path` for deterministic tests
- live upstream HTTP streaming via `net.http` progress callbacks

The current contract is:

- request goes to `POST /api/chat`
- request body uses `stream: true`
- upstream codec is `ndjson`
- mapper is `ndjson_text_field` or `ndjson_sse_field`

## Why generic plan instead of Ollama-specific runtime code

This keeps `vhttpd` reusable.

The runtime should understand:

- upstream transport
- upstream codec
- downstream mapper/output mode

It should not hardcode:

- provider URLs
- Ollama-only request semantics everywhere

That way the same mechanism can later support:

- Ollama-compatible endpoints
- OpenAI-compatible NDJSON/SSE variants
- other streaming upstreams

## Current MVP result

`vhttpd` now accepts a worker result that returns an upstream plan, opens the
upstream stream itself, decodes NDJSON, and maps it into downstream `text` or
`sse` output.

This is the first version where:

- browser stream does not lock a worker
- upstream Ollama stream also does not lock a worker

The validated fixture output is:

- `/ollama/text` -> `Hello from VSlim`
- `/ollama/sse` -> `token` events followed by `done`

## Error model in current MVP

Current MVP behavior is now:

- invalid plan contract (`transport/codec/mapper`) -> direct `502 Bad Gateway`
- upstream failure before the first downstream chunk:
  - `text` -> direct `502` with a plain-text body
  - `sse` -> direct `502`, then `error` event, then final `done`
- upstream failure after downstream streaming has already started:
  - `text` -> append a plain-text error tail and terminate chunked response
  - `sse` -> emit `error`, then final `done`
- worker planning/runtime failures still surface through the normal worker error model

This keeps one simple rule:

- before the first downstream bytes, `vhttpd` can still surface a real HTTP error status
- after downstream streaming has started, errors become stream-level events/tails
