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

## Asynchronous SQL Database

Embedded handlers expose `ctx.runtime.db` (MySQL and PostgreSQL). Build with
`-d enable_db` / `make build WITH_DB=1` and enable the existing `[db]` runtime
configuration. No new connection configuration is needed. Credentials remain
inside V; JS cannot choose a driver, connection URL, or another pool. This is an
optional trusted host capability, independent of `enableNetwork`. Reduced hosts
without database access reject with `database_unavailable`; disabled/uncompiled
database access rejects rather than returning a successful empty result.
Version-2 plans can use their existing `resources.db` configuration; the API
currently binds the application's active dbx pool, not a JS-selectable pool map.

```js
const db = ctx.runtime.db;
// MySQL uses ?; PostgreSQL uses $1, $2, ... . Parameters are strings.
const users = await db.query("SELECT id, name FROM users WHERE id = $1", ["42"], {
  timeoutMs: 2000,
  signal: controller.signal,
});
await db.transaction(async tx => {
  await tx.execute("UPDATE accounts SET balance = balance - 10 WHERE id = $1", ["1"]);
  await tx.execute("UPDATE accounts SET balance = balance + 10 WHERE id = $1", ["2"]);
}, { timeoutMs: 5000, signal: controller.signal });
```

`query(sql, params = [], options = {})` and `execute(...)` return real Promises.
Results preserve dbx field names: `ok`, `driver`, `columns`, `rows`,
`affected_rows`, `last_insert_id`, `session_id`. Query values are strings; the
existing dbx adapter maps SQL NULL to `""` (not a typed/null-preserving API).
MySQL supplies affected rows and insert ID. PostgreSQL `execute().affected_rows`
is `null` because the current V pg.Result does not expose command row counts;
use `query("... RETURNING ...")` when those rows/IDs are required. Use bound
parameters, never SQL interpolation. Driver errors reject the Promise.

`timeoutMs` defaults to 30,000 and must be a positive signed-32-bit integer.
Timeout rejects with `TimeoutError`; AbortSignal cancellation uses `AbortError`.
Deadlines include pool/transaction admission waits and are checked on workers
as well as the owning JS lane. Workers carry only V data and completion ports;
completion uses the same host-async queue and owner-scoped lane wakeups as HTTP.
An owner-only 5ms compatibility pump also supports handlers awaiting results.
Each lane accepts at most 64 outstanding native DB operations (plus 32 reserved
rollback-cleanup admissions), with the existing
shared pool limiting physical connections. Busy admission rejects immediately.

`transaction(callback, options)` pins one pooled connection, serializes its SQL,
and resolves to the callback result after commit. Submitted operations are
tracked before commit, even if the callback forgot to await them. A failed,
timed-out, or cancelled operation dooms the transaction even if the callback
catches its error. Query-level `timeoutMs` and `signal` are supported within a
transaction; transaction-level options bound its lifetime, including an idle
callback. A transaction object cannot be used after completion. Callback failure
rolls back; lane close rolls back all owned transactions before returning their
connections. Do not send raw BEGIN/COMMIT/ROLLBACK through query/execute, and do
not nest transaction callbacks on an exhausted pool.
Concurrent transaction statements are serialized but do not guarantee submission
order; use sequential `await` for dependent statements.

Cancellation is **logical cancellation**, not server-side SQL interruption.
Queued cancelled work never executes. Already-running SQL keeps its lease until
the native driver returns; cancellation does not release a busy connection for
reuse. Cancelled transactions then roll back/reset before reuse. Normal writes
already sent outside a transaction may still take effect; cancellation racing
COMMIT can have an unknown commit outcome. Do not automatically retry such writes.
No SQL is automatically replayed. Database/server transport limits remain
necessary for permanently stalled native calls; KILL QUERY/PQcancel is not yet
implemented. Cancelling JS waiting does not guarantee database-side cancellation.

### TODO: Driver-supported server-side cancellation (deferred)

Deferred at the user's request until V's database drivers provide the required
safe cancellation APIs. No driver changes are part of the current implementation;
the logical-cancellation contract above remains unchanged.

- PostgreSQL: expose an independently owned `PGcancel` handle through `db.pg`,
  then use `PQcancel` without concurrently accessing the active `PGconn`.
- MySQL: add a supported cancellation API/connection identity to `db.mysql`,
  then send `KILL QUERY` through an independent control connection.
- Keep each lease reserved until its SQL and cancellation work have both ended.
  Resolve completion/cancellation races without allowing a late cancel to affect
  rollback, connection reset, or a subsequent borrower's query.
- Verify actual server-side interruption on timeout and AbortSignal cancellation,
  transaction rollback, pool recovery/reuse, and cancel-versus-completion races
  against isolated MySQL and PostgreSQL instances. A prompt JS rejection alone
  is not evidence that the SQL stopped.

Integration tests require dedicated disposable databases named
`vhttpd_async_test` (the fixture drops/recreates `vjsx_async_items`). Never point
them at production. MySQL test user is `root` with no password; PostgreSQL test
user is `vhttpd_test` with local trust authentication:

```sh
VHTTPD_TEST_MYSQL_PORT=13316 VHTTPD_TEST_PG_PORT=15442 \
VJS_QUICKJS_PATH=/path/to/quickjs \
v -d build_quickjs -d use_openssl -d enable_db -enable-globals \
  -path 'src|@vlib|@vmodules' -cc clang test src/executor/database_async_test.v
```

Without explicit test ports (or without `enable_db`) real database tests print
SKIP. They cover parallel/timer progress, shared pool admission across lanes,
commit/rollback/parameter binding, transaction serialization, deadlines, aborts,
pre-aborts, cancelled waiters, worker bounds, recovery, detached completion and
in-flight lane-close rollback.

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
