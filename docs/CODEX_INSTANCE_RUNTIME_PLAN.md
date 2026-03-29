**Codex Instance Runtime Plan**

This document fixes the ownership boundary for Codex multi-instance support between `examples/codexbot-app-ts` and `vhttpd`.

**Goals**

- Let `vhttpd` fully own Codex provider connections, reconnect, handshake, and runtime state.
- Let TS/vjsx only choose `instance`, persist dynamic config, and orchestrate business flows.
- Keep the existing single-instance path compatible while enabling incremental rollout for multi-instance Codex.

**Ownership**

- TS/vjsx owns:
  - instance selection per project/chat/stream
  - durable instance spec persistence
  - app-level bootstrap intent via `app_startup(runtime)`
  - deciding when to issue `provider.instance.upsert`
  - deciding when to issue `provider.instance.ensure`
  - issuing business commands with an explicit `instance`
- `vhttpd` owns:
  - in-memory provider instance registry
  - Codex runtime materialization per instance
  - websocket connect/reconnect loop
  - initialize/initialized/thread-start handshake
  - runtime state such as connection, current thread, pending RPCs, and per-instance metrics
  - serializing `app_startup(runtime)` so only one lane executes process-global startup work
  - running `startup(runtime)` once per lane for lane-local initialization

**Canonical Flow**

1. `vhttpd` loads the app and may call `startup(runtime)` once per lane.
2. `vhttpd` calls `app_startup(runtime)` once per app load.
3. TS app startup can emit `provider.instance.upsert` with the desired Codex instance config snapshot.
4. TS app startup can emit `provider.instance.ensure` so `vhttpd` materializes the runtime early.
5. During normal business flow, TS resolves the effective Codex instance for the current project/chat/stream.
6. Business commands such as `session.turn.start` and `provider.rpc.call` carry the same `instance`.
7. Follow-up actions must continue using the stream-bound instance snapshot rather than recomputing from current chat/project defaults.

**Compatibility Rules**

- TS uses `"default"` as the public default instance name.
- `vhttpd` normalizes empty or `"default"` to `"main"` internally.
- Until the command wire schema grows a first-class nested `config` object, TS serializes provider config into `content`, and `desired_state` travels in metadata.
- Feishu remains on the current runtime model for now. This phase only generalizes Codex.

**Runtime Model in `vhttpd`**

- `provider_instance_specs` stores normalized instance specs keyed by `provider/instance`.
- `codex_runtime` remains the compatibility runtime for `main`.
- `codex_instances` stores additional materialized runtimes for non-main instances.
- `provider_runtime_instances('codex')` is the union of:
  - built-in `main` when the base Codex provider is enabled
  - any dynamically registered Codex instances

**What Is Landed in This Phase**

- TS-side instance persistence and resolution for project/chat/stream state.
- TS-side startup hooks:
  - `startup(runtime)` for lane-local initialization
  - `app_startup(runtime)` for process-global provider preflight
- TS-side preflight commands:
  - `provider.instance.upsert`
  - `provider.instance.ensure`
- `vhttpd` instance spec registry and compatibility parsing for instance upsert/ensure.
- `vhttpd` executor support for startup hooks:
  - `startup(runtime)` runs once per lane
  - `app_startup(runtime)` runs once per source signature and is serialized across lanes
- `vhttpd` Codex lifecycle helpers that are now instance-aware:
  - pull URL
  - reconnect delay
  - connecting/connected/disconnected callbacks
  - handshake config lookup
  - runtime snapshots and metrics

**Next Phase**

- Thread `instance` through the remaining Codex business path end-to-end:
  - send RPC
  - reply RPC
  - response dispatch
  - notification handling
  - stream target binding lookup
- After that, non-main Codex instances become fully isolated execution lanes rather than only isolated connection runtimes.
