# Paseo Relay Skeleton

This example is a `vhttpd + vjsx` skeleton for a Paseo-compatible relay.

It is intentionally modeled after the upstream behavior in:

- `packages/relay/src/cloudflare-adapter.ts`

Current scope:

- `GET /health`
- `GET /healthz`
- `GET /state`
- `GET /ws?...` websocket relay endpoint
- v2 relay skeleton:
  - `server-control`
  - `server-data(connectionId)`
  - `client(connectionId)`
  - `sync`
  - `connected`
  - `disconnected`
  - pending client frame buffering
  - text/binary frame forwarding
  - control sync/reset nudge timers
- minimal v1 compatibility skeleton

Important constraints:

- this example currently relies on in-memory relay state
- use `vjsx.thread_count = 1`
  - multi-lane `vjsx` would split relay state across lanes
- control-channel sync/reset nudges now use `runtime.websocketDispatch(...)` so
  `setTimeout(...)` callbacks can emit websocket hub commands after the original
  event handler has returned

Run:

```bash
cd /Users/guweigang/Source/vhttpd
./vhttpd --config /Users/guweigang/Source/vhttpd/examples/config/paseo-relay.toml
```

Endpoints:

- `http://127.0.0.1:19901/health`
- `http://127.0.0.1:19901/healthz`
- `http://127.0.0.1:19901/state`
- `ws://127.0.0.1:19901/ws?serverId=<id>&role=<server|client>&v=2`

Notes:

- `role=server` without `connectionId` is treated as v2 control
- `role=server` with `connectionId` is treated as v2 server-data
- `role=client` without `connectionId` gets a server-assigned connection id
- the relay does not inspect encrypted payloads
- v1 and v2 sessions are isolated by `serverId + version`, matching upstream relay
  instance routing
