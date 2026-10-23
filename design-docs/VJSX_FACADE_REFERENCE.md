# vjsx Facade Reference

This document summarizes the in-proc `vjsx` facade exposed by `vhttpd`.

Current scope is request/response style HTTP handling plus websocket event
dispatch in embedded `vjsx` mode.

## Entry Resolution

`vhttpd` resolves the handler in this order:

1. `export default`
2. `export const handle`
3. `globalThis.__vhttpd_handle`

Recommended style is `export default`.

For bot-style apps, a convenient TS entry shape is:

1. `export default function http(ctx) {}`
2. `export const websocket = (frame) => ({ accepted, commands })`
3. `export const websocket_upstream = (frame) => ({ handled, commands })`
4. `export const snapshot = (runtime) => ({ ... })`
5. `export default { http(ctx) {}, websocket(frame) {}, websocket_upstream(frame) {}, snapshot(runtime) {} }`

## Runtime

`ctx.runtime` exposes read-only execution metadata:

- `provider`
- `executor`
- `laneId`
- `requestId`
- `traceId`
- `appEntry`
- `moduleRoot`
- `runtimeProfile`
- `threadCount`
- `method`
- `path`
- `capabilities`
- `request`

Methods:

- `runtime.now()`
- `runtime.log(...args)`
- `runtime.warn(...args)`
- `runtime.error(...args)`
- `runtime.emit(kind, fields)`
- `runtime.snapshot(input?, fallbackValue?)`
- `runtime.readTextFile(path, fallbackValue?)`
- `runtime.findCodexSessionPath(threadId, fallbackValue?)`
- `await runtime.httpFetch(input, fallbackValue?)`
- `runtime.bridgeDispatch(input, fallbackValue?)`
- `runtime.websocketDispatch(input, fallbackValue?)`

Additional runtime fields:

- `runtime.dispatchKind`
- `runtime.upstream` when dispatch kind is `websocket_upstream`

## Host API

`vhttpd` now installs its embedder-facing host surface through `vjsx.HostApiConfig`
rather than ad-hoc global callbacks.

Current host globals:

- `globalThis.vhttpdHost`

Current host helpers:

- `vhttpdHost.emit(kind, fields)`
- `vhttpdHost.snapshot()`
- `vhttpdHost.readTextFile(path, fallbackValue?)`
- `vhttpdHost.findCodexSessionPath(threadId, fallbackValue?)`
- `vhttpdHost.httpFetch(url, init)` (internal native fetch bridge)
- `vhttpdHost.bridgeDispatch(input)`
- `vhttpdHost.websocketDispatch(input)`

`runtime.request` exposes read-only request metadata:

- `id`
- `traceId`
- `method`
- `path`
- `url`
- `target`
- `href`
- `origin`
- `scheme`
- `host`
- `port`
- `protocolVersion`
- `remoteAddr`
- `ip`
- `server`

## Asynchronous HTTP Fetch

`runtime.httpFetch()` returns a Promise. Callers previously reading properties
directly from its result must add `await`, including the network-disabled path.
It uses vjsx's native background HTTP transport and shared host-async completion
queue; it does not perform network I/O inside the JS lane.

```js
const controller = new AbortController();
const [one, two] = await Promise.all([
  ctx.runtime.httpFetch({ url: firstUrl, timeoutMs: 2000, signal: controller.signal }),
  ctx.runtime.httpFetch({ url: secondUrl, timeoutMs: 2000 }),
]);
```

Input accepts `url`, `method`, `headers`, `body`, `timeoutMs`, and `signal`.
`timeoutMs` defaults to 30,000 and must be a finite positive number. The native
transport also retains its own total deadline and concurrency limit; a larger
per-call timeout does not extend those host limits. Success resolves to
`{ ok: true, status, body, headers }`, including HTTP 4xx/5xx responses.
Transport failures resolve to `{ ok: false, error, errorName }`. Cancellation
uses `AbortError`; per-call timeout uses `TimeoutError`. A disabled network
capability resolves to the supplied fallback (undefined by default).

Completion callbacks only enqueue owner-scoped lane work. An idle lane drains
the completion queue on its worker before pumping Promise continuations. Timer
wakeups and completion wakeups have separate pending slots; retired session
callbacks cannot wake a replacement session.

Cancellation ends JS waiting promptly. An already-running V HTTP socket may
continue until it finishes or reaches its transport timeout, retaining its
native concurrency slot. The body is buffered before this facade returns.

## Request Context

Primary aliases:

- `ctx.req`
- `ctx.res`
- `ctx.request`
- `ctx.response`

Core request fields:

- `ctx.requestId`
- `ctx.traceId`
- `ctx.method`
- `ctx.path`
- `ctx.url`
- `ctx.target`
- `ctx.href`
- `ctx.origin`
- `ctx.scheme`
- `ctx.host`
- `ctx.port`
- `ctx.protocolVersion`
- `ctx.remoteAddr`
- `ctx.ip`
- `ctx.server`
- `ctx.body`
- `ctx.headers`
- `ctx.query`
- `ctx.cookies`

## Request Helpers

General helpers:

- `ctx.queryParam(name, fallbackValue)`
- `ctx.queryInt(name, fallbackValue)`
- `ctx.queryBool(name, fallbackValue)`
- `ctx.cookie(name, fallbackValue)`
- `ctx.is(method)`
- `ctx.getHeader(name)`
- `ctx.headerInt(name, fallbackValue)`
- `ctx.headerBool(name, fallbackValue)`
- `ctx.bodyText(fallbackValue)`
- `ctx.jsonBody(fallbackValue)`

Negotiation helpers:

- `ctx.contentType()`
- `ctx.accepts(...types)`
- `ctx.isJson()`
- `ctx.isHtml()`
- `ctx.wantsJson()`
- `ctx.wantsHtml()`

## Response Helpers

Header and status helpers:

- `ctx.status(code)`
- `ctx.code(code)`
- `ctx.setHeader(name, value)`
- `ctx.getHeader(name)`
- `ctx.hasHeader(name)`
- `ctx.removeHeader(name)`
- `ctx.header(name, value?)`
- `ctx.type(contentType)`

Body helpers:

- `ctx.text(body, status?)`
- `ctx.json(value, status?)`
- `ctx.html(body, status?)`
- `ctx.send(body, status?)`
- `ctx.reply(body, status?)`

Semantic helpers:

- `ctx.ok(value)`
- `ctx.created(value?)`
- `ctx.accepted(value?)`
- `ctx.noContent()`
- `ctx.badRequest(value?)`
- `ctx.unprocessableEntity(value?)`
- `ctx.notFound(value?)`
- `ctx.problem(status, title, detail?, extra?)`
- `ctx.redirect(location, status?)`

## Notes

- `ctx.url` keeps the normalized path-style value for compatibility.
- `ctx.target` preserves the full request target including query string when present.
- `ctx.problem(...)` returns `application/problem+json; charset=utf-8`.
- `runtime.snapshot()` is read-only and backed by `vhttpd` runtime/admin snapshot logic.
- `runtime.snapshot({ scope: "all_lanes", kind: "app" })` aggregates the optional `snapshot(runtime)` hook across all embedded `vjsx` lanes and returns `{ scope, kind, currentLaneId, lanes: [{ laneId, available, snapshot, error }] }`.
- `runtime.snapshot({ scope: "other_lanes", kind: "app" })` aggregates the optional `snapshot(runtime)` hook across every other embedded `vjsx` lane and is the safer choice from inside an active handler when the app already has direct access to its current-lane local state.
- `runtime.websocketDispatch(...)` executes websocket hub commands from host-side async
  callbacks such as `setTimeout(...)`.
- Embedded websocket timers are not driven by a background poller. After host-side
  async sources such as `setTimeout(...)` become ready, the embedder must
  explicitly pump the owning lane session, for example via
  `InProcVjsxExecutor.pump_all_lane_sessions()`.
- Current embedded `vjsx` scope is HTTP dispatch plus websocket event dispatch and `websocket_upstream` dispatch. Stream and MCP worker modes are not exposed through this facade.

## WebSocket Frame

When `dispatchKind === "websocket"`, the handler receives a frame object with:

- `frame.mode`
- `frame.event`
- `frame.id`
- `frame.path`
- `frame.query`
- `frame.headers`
- `frame.remoteAddr`
- `frame.requestId`
- `frame.traceId`
- `frame.targetId`
- `frame.room`
- `frame.key`
- `frame.value`
- `frame.exceptId`
- `frame.rooms`
- `frame.metadata`
- `frame.roomMembers`
- `frame.memberMetadata`
- `frame.roomCounts`
- `frame.presenceUsers`
- `frame.status`
- `frame.code`
- `frame.reason`
- `frame.opcode`
- `frame.data`
- `frame.error`
- `frame.errorClass`
- `frame.runtime`

Helpers:

- `frame.dataText(fallbackValue)`
- `frame.dataBase64(fallbackValue)`
- `frame.dataJson(fallbackValue)`

Return shape:

- `false` or `null` for `{ accepted: false, commands: [] }`
- `true` for `{ accepted: true, commands: [] }`
- `Command[]` for `{ accepted: true, commands }`
- `{ accepted?: boolean, closed?: boolean, commands?: Command[], error?: string, errorClass?: string }`

## WebSocket Upstream Frame

When `dispatchKind === "websocket_upstream"`, the handler receives a frame object with:

- `frame.mode`
- `frame.event`
- `frame.id`
- `frame.provider`
- `frame.instance`
- `frame.traceId`
- `frame.eventType`
- `frame.messageId`
- `frame.target`
- `frame.targetType`
- `frame.payload`
- `frame.receivedAt`
- `frame.metadata`
- `frame.runtime`

Helpers:

- `frame.payloadText(fallbackValue)`
- `frame.payloadJson(fallbackValue)`

Return shape:

- `false` or `null` for `{ handled: false, commands: [] }`
- `true` for `{ handled: true, commands: [] }`
- `Command[]` for `{ handled: true, commands }`
- `{ handled?: boolean, commands?: Command[] }`
