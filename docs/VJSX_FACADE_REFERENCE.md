# vjsx Facade Reference

This document summarizes the in-proc `vjsx` facade exposed by `vhttpd`.

Current scope is request/response style HTTP handling in embedded `vjsx` mode.

## Entry Resolution

`vhttpd` resolves the handler in this order:

1. `export default`
2. `export const handle`
3. `globalThis.__vhttpd_handle`

Recommended style is `export default`.

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
- `runtime.snapshot()`

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
- Current embedded `vjsx` scope is one-shot HTTP dispatch. Stream and websocket worker modes are not exposed through this facade.
