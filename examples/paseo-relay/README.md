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
- relay correctness now relies on `websocket_actor` serialization
  - the default config uses actor-style serialization by `connectionId`
  - multi-lane `vjsx` is supported, but ordering correctness should come from
    actor serialization rather than sticky lane affinity
- relay session state lives in host-managed memory rather than lane-local memory
  - because state is stored outside a specific lane, fixed-lane execution is no
    longer required for correctness
  - `websocket_affinity` should be treated as an optional scheduling optimization,
    not as a correctness mechanism for the relay
- control-channel sync/reset nudges now use `runtime.websocketDispatch(...)` so
  `setTimeout(...)` callbacks can emit websocket hub commands after the original
  event handler has returned

Run:

```bash
cd /Users/guweigang/Source/vhttpd
./vhttpd --config /Users/guweigang/Source/vhttpd/examples/paseo-relay/paseo-relay.toml
```

Actor-only comparison config:

```bash
./vhttpd --config /Users/guweigang/Source/vhttpd/examples/paseo-relay/paseo-relay-no-sticky.toml
```

Design note:

- the relay keeps an application-level buffer by `connectionId` until `server-data`
  exists for that connection
- the websocket hub keeps a lower-level pending buffer only for already-resolved
  socket targets that are not yet ready to write
- these two buffers serve different layers and should not be treated as interchangeable

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
