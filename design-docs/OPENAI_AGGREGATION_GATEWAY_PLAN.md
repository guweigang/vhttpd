# OpenAI Aggregation Gateway Plan

## Goal

Build vhttpd into an OpenAI-compatible aggregation gateway.

The important boundary is:

- vhttpd owns network execution, stream lifecycle, SSE writing, upstream HTTP,
  timeout/cancellation, tracing, auth envelope, and backpressure.
- vjsx owns protocol intelligence: OpenAI compatibility mapping, model routing,
  backend-specific request/response shaping, validation, and policy.

In short, vhttpd should keep the data plane. vjsx should act as a protocol
plugin and planning/mapping layer.

## Why This Shape

OpenAI-compatible aggregation has two very different responsibilities.

The first is physical IO: accepting client HTTP requests, holding long-running
connections, reading upstream streams, detecting disconnects, enforcing
timeouts, and writing SSE frames. This belongs in vhttpd because it is closer to
the server runtime and existing stream/upstream machinery.

The second is protocol adaptation: deciding which backend should serve a model,
converting OpenAI requests into upstream-specific requests, normalizing provider
quirks, and mapping chunks back into OpenAI-compatible responses. This is a good
fit for vjsx because TypeScript has mature libraries and schemas for this
ecosystem, and protocol logic can evolve faster outside the core server.

## Runtime Boundary

```text
client
  -> vhttpd /v1/*
  -> vhttpd parses request, auth, trace, lifecycle
  -> vjsx protocol plugin returns a declarative plan
  -> vhttpd executes upstream HTTP/executor plan
  -> vhttpd decodes frames: sse | ndjson | json | text
  -> optional vjsx frame mapper
  -> vhttpd writes OpenAI-compatible JSON/SSE
```

vjsx should not own sockets for this feature. It should return plans and mapping
decisions. vhttpd should own the actual fetch, stream read, and client write.

## Responsibilities

### vhttpd Owns

- `/v1/*` HTTP dispatch surface.
- Client connection takeover and SSE/chunked response writing.
- Upstream HTTP execution.
- Upstream stream decoding at the transport/framing layer.
- Cancellation when the client disconnects.
- Timeout and retry hooks.
- Request ids, trace ids, response headers, access logs, and admin snapshots.
- Fast-path passthrough for already OpenAI-compatible upstream streams.

### vjsx Owns

- Model alias and route selection.
- Backend-specific request construction.
- OpenAI request normalization and validation.
- Upstream response and error mapping.
- Provider-specific quirks.
- Optional policy: fallback, tenant routing, capability selection.

## Configuration Shape

Prefer named map sections, matching the existing vhttpd style.

```toml
[openai]
enabled = true
base_path = "/v1"
plugin = "openai-gateway"

[openai.endpoints]
models = true
chat_completions = true
responses = true
embeddings = false

[openai.routes.gpt4omini]
models = ["gpt-4o-mini", "gpt-4o-mini-*"]
backend = "openai-main"
upstream_model = "gpt-4o-mini"

[openai.routes.local-chat]
models = ["llama3.1", "qwen2.5"]
backend = "ollama-local"

[openai.routes.agent]
models = ["my-agent", "company-assistant"]
backend = "agent-vjsx"

[openai.backends.openai-main]
kind = "openai_http"
base_url = "https://api.openai.com/v1"
api_key_env = "OPENAI_API_KEY"
stream_mode = "passthrough"

[openai.backends.ollama-local]
kind = "http"
base_url = "http://127.0.0.1:11434"
stream_mode = "mapped"
protocol_plugin = "openai_ollama"

[openai.backends.agent-vjsx]
kind = "executor"
executor = "agent-vjsx"
stream_mode = "vhttpd_sse"

[plugins.agent-vjsx]
kind = "vjsx"
entry = "plugins/agent-executor.mts"
runtime_profile = "node"
enable_network = true

[plugins.openai-gateway]
kind = "vjsx"
entry = "plugins/openai-gateway.mts"
runtime_profile = "node"
thread_count = 1
enable_network = false
```

Site-level overrides should be allowed later:

```toml
[sites.ai_gateway]
host = "127.0.0.1"
port = 19890
openai.enabled = true
openai.base_path = "/v1"
```

## Protocol Plugin Contract

The plugin should return declarative plans, not perform network IO.

TypeScript shape:

```ts
type OpenAIPluginRequest = {
  plugin: string;
  capability: "openai";
  op:
    | "models"
    | "chat.route"
    | "chat.execute"
    | "chat.fallback"
    | "chat.map_frame"
    | "responses.route"
    | "responses.execute"
    | string;
  request_id: string;
  trace_id: string;
  payload: string;
  metadata: Record<string, string>;
};

type OpenAIModelsResult =
  | { not_handled: true }
  | { models: string[] }
  | { data: Array<{ id: string }> };

type OpenAIChatRoutePlan =
  | { not_handled: true }
  | {
      backend: string;
      method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD";
      path?: `/${string}`;
      headers?: Record<string, string>;
      body?: string;
      upstream_model?: string;
      stream_mode?: "passthrough" | "mapped";
      response_codec?: "sse" | "json" | "ndjson" | "text";
      output_protocol?: "openai.chat.completion";
      mapper?: "builtin" | "plugin";
    };
```

Example:

```ts
export function openai(req) {
  switch (req.op) {
    case "models":
      return { models: ["gpt-4o-mini"] };

    case "chat.route": {
      const payload = JSON.parse(req.payload);
      return {
        backend: "openai-main",
        method: "POST",
        path: "/chat/completions",
        headers: {},
        body: payload.body,
        stream_mode: "passthrough",
      };
    }

    default:
      return { not_handled: true };
  }
}
```

Example upstream plan:

```ts
return {
  backend: "ollama-local",
  method: "POST",
  path: "/api/chat",
  headers: {},
  body: JSON.stringify({ model: "llama3.1", messages, stream: true }),
  stream_mode: "mapped",
  response_codec: "ndjson",
  output_protocol: "openai.chat.completion",
  mapper: "builtin",
};
```

vhttpd executes the plan and exposes framed upstream data back to the plugin
only when mapping is required.

Plugin frame mapper example:

```ts
export function openai(req) {
  if (req.op === "chat.map_frame") {
    const payload = JSON.parse(req.payload);
    const frame = JSON.parse(payload.frame);
    return {
      content: frame.delta ?? "",
      tool_calls: frame.tool_calls ?? undefined,
      finish_reason: frame.tool_calls ? "tool_calls" : undefined,
      done: frame.finished === true,
    };
  }
  return { not_handled: true };
}
```

Plugin fallback example:

```ts
export function openai(req) {
  if (req.op === "chat.fallback") {
    const payload = JSON.parse(req.payload);
    if (payload.failed_backend !== "primary" || payload.status_code < 500) {
      return { not_handled: true };
    }
    return {
      backend: "backup",
      method: "POST",
      path: "/chat/completions",
      body: payload.body,
      stream_mode: "passthrough",
    };
  }
  return { not_handled: true };
}
```

## Executor Backend Contract

An executor backend is used when vhttpd should not directly call the upstream
HTTP API. This is the escape hatch for private SDKs, non-OpenAI-compatible
protocols, multi-step agent logic, or provider-specific network behavior.

Configuration:

```toml
[openai.backends.custom_executor]
kind = "executor"
executor = "custom_executor"

[plugins.custom_executor]
kind = "vjsx"
entry = "examples/vjsx/openai-executor-app.mts"
runtime_profile = "node"
enable_network = true
```

The OpenAI routing plugin can select this backend:

```ts
return {
  backend: "custom_executor",
  method: "POST",
  path: "/executor/chat",
  body: payload.body,
  stream_mode: "executor",
};
```

The executor app only needs to implement the `openai(req)` entry and handle
`req.op === "chat.execute"` for Chat Completions or
`req.op === "responses.execute"` for Responses.

Request shape:

```ts
type OpenAIExecutorRequest = {
  plugin: string;
  capability: "openai";
  op: "chat.execute" | "responses.execute";
  request_id: string;
  trace_id: string;
  payload: string;
  metadata: {
    model?: string;
    backend?: string;
  };
};

type OpenAIExecutorPayload = {
  method: string;
  path: string;
  model: string;
  stream: boolean;
  body: string;
  backend: string;
  request_id: string;
  trace_id: string;
  response_codec?: string;
  output_protocol?: "openai.chat.completion" | "openai.response";
};
```

Minimal executor:

```ts
export async function openai(req) {
  if (req.op !== "chat.execute") {
    return { not_handled: true };
  }
  const payload = JSON.parse(req.payload);
  const body = JSON.parse(payload.body);

  // Call a private SDK or non-OpenAI HTTP API here.
  if (payload.stream) {
    return {
      frames: [
        { content: "hello", done: false },
        { usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }, done: true },
      ],
    };
  }

  return {
    content: "hello",
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    done: true,
  };
}
```

Non-stream normalized result:

```ts
return {
  content: "hello",
  usage: {
    prompt_tokens: 10,
    completion_tokens: 3,
    total_tokens: 13,
  },
  done: true,
};
```

vhttpd turns that into an OpenAI `chat.completion` response.

Non-stream full OpenAI body:

```ts
return {
  body: JSON.stringify({
    id: "chatcmpl-custom",
    object: "chat.completion",
    choices: [
      {
        index: 0,
        message: { role: "assistant", content: "hello" },
        finish_reason: "stop",
      },
    ],
  }),
};
```

Stream result:

```ts
return {
  frames: [
    { content: "hello ", done: false },
    { content: "world", done: false },
    {
      usage: {
        prompt_tokens: 10,
        completion_tokens: 2,
        total_tokens: 12,
      },
      done: true,
    },
  ],
};
```

vhttpd writes these frames as OpenAI SSE and appends `data: [DONE]`.

Tool call frame:

```ts
return {
  frames: [
    {
      tool_calls: [
        {
          index: 0,
          id: "call_1",
          type: "function",
          function: {
            name: "search",
            arguments: "{\"q\":\"vhttpd\"}",
          },
        },
      ],
      finish_reason: "tool_calls",
      done: true,
    },
  ],
};
```

Error result:

```ts
return {
  error: {
    message: "custom provider failed",
  },
};
```

Current executor behavior:

- Executor apps may perform network access when their plugin config enables it.
- vhttpd still owns the client-facing OpenAI HTTP/SSE response.
- Non-stream executor results are normalized into OpenAI JSON unless `body` is
  returned.
- Stream executor results can return either buffered `frames: [...]` or an async
  iterable. Async iterable results are pulled by vhttpd through vjsx
  `RuntimeSession.stream_value(...)`, so each yielded frame is written as SSE
  before the next frame is requested.

Current plan validation:

- `backend` is required and must name a configured backend.
- `method` defaults to `POST` and must be one of `GET`, `POST`, `PUT`,
  `PATCH`, `DELETE`, `HEAD`.
- `path` defaults to `/chat/completions`, must start with `/`, and must not
  contain newlines.
- `stream_mode` defaults to `passthrough`; `mapped` is supported for OpenAI
  chat completion mapping.
- `mapped` currently supports `response_codec = "ndjson"` for streaming and
  `response_codec = "ndjson" | "json"` for non-stream aggregation.
- `output_protocol` defaults to `openai.chat.completion`.
- `mapper` defaults to `builtin`; `plugin` calls `openai(req)` with
  `req.op = "chat.map_frame"` per decoded upstream frame.
- hop-by-hop headers such as `Connection`, `Content-Length`,
  `Transfer-Encoding`, `Host`, and `Upgrade` are ignored.

## Stream Modes

### passthrough

For OpenAI-compatible upstreams. vhttpd forwards the request upstream and writes
the upstream response back to the client with minimal intervention.

Useful for:

- OpenAI official API.
- OpenAI-compatible providers.
- Other aggregation gateways.

vjsx is used for route/build-start/error hooks, not per-token mapping.

### mapped

For non-OpenAI upstreams such as Ollama NDJSON. vhttpd decodes the upstream
framing and calls vjsx or a built-in mapper to emit OpenAI-compatible chunks.

Useful for:

- Ollama `/api/chat` NDJSON.
- custom JSONL/NDJSON model servers.
- providers with incompatible stream shape.

### vhttpd_sse

For executor backends where PHP/vjsx returns normalized events or frames, but
vhttpd still owns the client-facing SSE writer.

Useful for:

- inproc vjsx agent executors.
- PHP application executors.
- local business logic pretending to be an OpenAI model.

## Initial MVP

1. Add OpenAI config structs and admin snapshot fields.
2. Add `ProviderRouteKind.openai`.
3. Add `/v1/models` and `/v1/chat/completions` dispatch behind `[openai]`.
4. Implement `openai_http` backend with non-stream and SSE passthrough.
5. Add vjsx hook for route/buildUpstream.
6. Add built-in OpenAI SSE writer:
   - `data: {...}\n\n`
   - `data: [DONE]\n\n`
7. Add fixture tests for OpenAI-compatible mock upstream.

## Current Implementation Slice

The first slice keeps the network path in vhttpd and implements the
OpenAI-compatible passthrough path directly:

- `[openai]` config, named `[openai.backends.*]`, and named
  `[openai.routes.*]`.
- `[plugins.*]` config for capability plugins that do not replace the site
  executor.
- `/v1/models` generated from configured route models, or from the
  OpenAI plugin `models` operation.
- `/v1/chat/completions` routed by request `model`, or planned by the OpenAI
  plugin `chat.route` operation.
- `openai_http` upstream backend with configured `base_url` and API key from
  `api_key` or `api_key_env`.
- non-stream request passthrough, with optional model rewrite when
  `upstream_model` is configured.
- stream request passthrough where vhttpd takes over the client connection and
  forwards upstream SSE bytes.
- mapped Ollama-style NDJSON streams where vhttpd decodes upstream JSON lines
  and emits OpenAI chat completion SSE chunks.
- mapped non-stream `ndjson`/`json` responses aggregated into an OpenAI chat
  completion response.
- executor backends using a vjsx app via `chat.execute`, for providers that
  need custom SDK/network logic outside vhttpd's HTTP/mapped fetch path.
- `/v1/responses` create endpoint with non-stream and stream passthrough. The
  built-in route resolver reuses `[openai.routes.*]` and sends upstream traffic
  to `/responses`.
- Responses stateful passthrough for paths under `/v1/responses/*`, including
  retrieve, cancel, input item listing, and future upstream-defined subroutes.
  vhttpd preserves the query string and still applies backend auth, trace
  headers, and error normalization.
- Responses executor backends using `responses.execute`. Non-stream executors
  may return a Response object or `{ body }`; stream executors may return an
  async iterable of typed Responses events.
- In-memory Responses registry for executor-owned responses. vhttpd stores
  completed executor Responses in a TTL-backed `MemoryStateStore` and serves
  `GET /v1/responses/{id}` locally when the id is known; unknown ids continue
  to upstream passthrough.
- plugin frame mapper hook for provider-specific stream frames that the
  built-in mapper does not understand.
- upstream non-2xx responses normalized into OpenAI error envelopes.
- streaming upstream non-2xx responses normalized before SSE headers are
  written.
- plugin frame mapper errors normalized into OpenAI-style SSE error frames.
- `chat.fallback` plugin hook: vhttpd retries once with a fallback plan when
  upstream fetch fails or returns non-2xx.
- stream-safe fallback for passthrough streams: fallback is allowed only before
  client SSE headers are written; after streaming begins, vhttpd sends an
  OpenAI-style SSE error instead of switching backend.
- stream-safe fallback for mapped NDJSON streams using the same pre-SSE-header
  boundary.
- tool call chunk normalization for mapped streams: built-in and plugin mappers
  can emit OpenAI-compatible `delta.tool_calls` and `finish_reason =
  "tool_calls"`.
- non-stream mapped NDJSON tool calls are aggregated into final
  `message.tool_calls`, including incremental `function.arguments` chunks.
- non-stream mapped usage normalization from OpenAI-style `usage` or
  Ollama-style `prompt_eval_count`/`eval_count` into OpenAI
  `usage.prompt_tokens`, `usage.completion_tokens`, and `usage.total_tokens`.
- stream mapped usage emits a final OpenAI-compatible chunk with `choices: []`
  and `usage` before `data: [DONE]` when upstream usage is available.
- optional vjsx OpenAI plugin hook through a single `openai(req)` entry. vhttpd
  passes `req.op` values such as `models`, `chat.route`, and
  `responses.route`; `{ not_handled: true }` falls back to built-in config
  behavior.

The plugin hook is intentionally scoped: it can route/build the upstream plan,
but it does not own sockets, fetch, or client streaming.

## Second Phase

1. Add provider-specific error code taxonomy.
2. Add retry/fallback policy limits and observability fields.
3. Add provider-specific Responses routing examples beyond passthrough and
   executor.

## Later Phases

- durable persistence for Responses objects when executor state must survive
  process restart or be shared across vhttpd instances.
- embeddings
- tool call chunk normalization
- usage aggregation
- tenant-aware routing
- weighted routing and health checks
- per-key quota hooks
- request/response audit events
- admin UI/runtime snapshots

## Testing Strategy

Default tests should avoid npm and network dependencies.

Use local mock upstreams in V tests for:

- OpenAI-compatible JSON response.
- OpenAI-compatible SSE response.
- upstream disconnect.
- malformed SSE.
- timeout/cancellation.
- route miss.

Use optional vjsx/npm integration fixtures for:

- `openai` SDK non-stream and stream.
- AI SDK `generateText`.
- AI SDK `streamText`.

The optional fixture should not run in the default `v test` suite.

## Key Design Rule

Do not let protocol plugins own the socket.

The plugin can decide, normalize, and map. vhttpd should execute, stream, cancel,
observe, and write.
