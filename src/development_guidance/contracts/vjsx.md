# vjsx script profile

Use the entry configured in the application and match its template. An HTTP handler is the default export and receives the host context `ctx`. Use relative imports for project modules supported by the selected runtime and check the installed template for entry and module layout. Script profile runs in QuickJS. Node built-ins, npm package resolution and Node globals are unavailable. Verify any host module with the selected package before using it.

| API | Behavior |
| --- | --- |
| `ctx.method` | HTTP method string |
| `ctx.path` | Request path |
| `ctx.queryParam(name, fallback)` | Query parameter or the supplied fallback |
| `ctx.text(value, status)` | Text response |
| `ctx.json(value, status)` | JSON response |

## HTTP handler

```js
export default function (ctx) {
  return ctx.text("hello", 200)
}
```

## JSON API handler

```js
export default function (ctx) {
  if (ctx.method === "GET" && ctx.path === "/api/hello") {
    return ctx.json({ message: ctx.queryParam("message", "hello") }, 200)
  }
  return ctx.json({ error: "not found" }, 404)
}
```

Use `schema_get` for `engines/vjsx` configuration and `application_request` on the bound business listener to check the status and response.
