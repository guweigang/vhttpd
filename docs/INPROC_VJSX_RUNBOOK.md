# In-Proc vjsx Runbook

This runbook verifies that `vhttpd` can run `vjsx` logic in-process without a PHP worker.

If you want the existing PHP worker path instead, use [config/vhttpd.example.toml](/Users/guweigang/Source/vhttpd/config/vhttpd.example.toml) with `[executor].kind = "php"` and the `[worker]` / `[worker.env]` sections. A side-by-side mode guide is available at [docs/EXECUTOR_MODES.md](/Users/guweigang/Source/vhttpd/docs/EXECUTOR_MODES.md).

## Prerequisites

- repo: `/Users/guweigang/Source/vhttpd`
- local `vjsx` module available in `~/.vmodules/vjsx`
- free local ports for data plane and admin plane

## Build

```bash
cd /Users/guweigang/Source/vhttpd
make vhttpd
```

## Start With Example Config

```bash
./vhttpd \
  --config /Users/guweigang/Source/vhttpd/config/vhttpd.vjsx.example.toml \
  --port 19892 \
  --admin-port 19992
```

The example config now uses `[paths]`, so the checked-in TOML stays portable instead of baking in repo-local absolute paths. Values that start with `/` stay absolute; other path values resolve relative to `[paths].root`.

Expected startup signals:

- data plane logs `http://127.0.0.1:19892/`
- admin plane logs `http://127.0.0.1:19992/admin`
- no PHP worker sockets are started

## Verify Data Plane

```bash
curl --noproxy '*' -sS -i \
  'http://127.0.0.1:19892/hello?name=codex'
```

Expected response:

- HTTP status `200`
- `content-type: application/json; charset=utf-8`
- body contains:
  - `"provider":"vjsx"`
  - `"executor":"vjsx"`
  - `"path":"/hello"`
  - `"name":"codex"`

The embedded `vjsx` facade also supports:

- `ctx.runtime.emit(kind, fields)` for structured event emission into `vhttpd` event logs
- `ctx.runtime.snapshot()` for a read-only runtime/admin summary snapshot
- semantic response helpers such as `ctx.created()`, `ctx.noContent()`, `ctx.badRequest()`, and `ctx.notFound()`
- additional response helpers such as `ctx.accepted()`, `ctx.unprocessableEntity()`, and `ctx.problem()`
- transpiled module cache is written under the system temp directory, so your `examples/` or app source tree is not polluted with `.vjsbuild` output
- request environment fields such as `ctx.target`, `ctx.href`, `ctx.origin`, `ctx.ip`, `ctx.host`, and `ctx.runtime.request`
- request negotiation helpers such as `ctx.contentType()`, `ctx.accepts()`, `ctx.isJson()`, `ctx.isHtml()`, `ctx.wantsJson()`, and `ctx.wantsHtml()`

For a broader example that exercises these helpers, see [examples/vjsx/api-demo-handler.mts](/Users/guweigang/Source/vhttpd/examples/vjsx/api-demo-handler.mts).

For a compact API summary, see [docs/VJSX_FACADE_REFERENCE.md](/Users/guweigang/Source/vhttpd/docs/VJSX_FACADE_REFERENCE.md).

## Verify Admin Plane

```bash
curl --noproxy '*' -sS \
  -H 'x-vhttpd-admin-token: change-me' \
  'http://127.0.0.1:19992/admin/runtime'
```

Expected runtime markers:

- `"worker_pool_size":0`
- `"http_requests_total":1` after one successful data-plane request
- `"stream_dispatch":false`
- `"websocket_dispatch":false`

## Stop

Press `Ctrl-C` in the `vhttpd` terminal.

## Notes

- If ports are already in use, override `--port` and `--admin-port`.
- In `vjsx` executor mode, `vhttpd` disables worker autostart and worker sockets automatically.
- Current scope is one-shot HTTP dispatch. Stream and websocket worker modes are intentionally off in this mode.
