# vhttpd Refactor Tracking

## Phase 2: Modularization (in progress)

### Completed extractions

| Module | Directory | Files | Status |
|--------|-----------|-------|--------|
| state_store | `src/state_store/` | state_store.v, state_store_test.v | ✅ Merged to refactor/v2 |
| jsonutils | `src/jsonutils/` | json_utils.v, json_utils_test.v | ✅ Merged to refactor/v2 |
| worker_protocol | `src/worker_protocol/` | worker_protocol.v | ✅ Merged to refactor/v2 |

### Transitional type aliases (tech debt)

**Location**: `src/main.v` (~L145)

`worker_protocol` structs are aliased back into `module main` so existing
callers don't need to change yet.  Once the remaining `module main` files
are updated to `import worker_protocol` and use qualified names, these aliases
must be removed:

- `pub type WorkerResponse = worker_protocol.WorkerResponse`
- `pub type WorkerStreamFrame = worker_protocol.WorkerStreamFrame`
- `pub type StreamDispatchRequest = worker_protocol.StreamDispatchRequest`
- `pub type StreamDispatchChunk = worker_protocol.StreamDispatchChunk`
- `pub type StreamDispatchResponse = worker_protocol.StreamDispatchResponse`
- `pub type WorkerUpstreamPlanFrame = worker_protocol.WorkerUpstreamPlanFrame`
- `pub type WorkerRequestPayload = worker_protocol.WorkerRequestPayload`
- `pub type WorkerWebSocketFrame = worker_protocol.WorkerWebSocketFrame`
- `pub type WorkerWebSocketDispatchResponse = worker_protocol.WorkerWebSocketDispatchResponse`
- `pub type WorkerWebSocketDispatchCommandFailure = worker_protocol.WorkerWebSocketDispatchCommandFailure`
- `pub type WorkerWebSocketDispatchCommandsResult = worker_protocol.WorkerWebSocketDispatchCommandsResult`
- `pub type WorkerWebSocketDispatchFailureEnvelope = worker_protocol.WorkerWebSocketDispatchFailureEnvelope`
- `pub type WorkerMcpDispatchRequest = worker_protocol.WorkerMcpDispatchRequest`
- `pub type WorkerMcpDispatchResponse = worker_protocol.WorkerMcpDispatchResponse`
- `pub type WorkerWebSocketUpstreamDispatchRequest = worker_protocol.WorkerWebSocketUpstreamDispatchRequest`
- `pub type WorkerWebSocketUpstreamCommand = worker_protocol.WorkerWebSocketUpstreamCommand`
- `pub type WorkerWebSocketUpstreamDispatchResponse = worker_protocol.WorkerWebSocketUpstreamDispatchResponse`

### Next candidates for extraction

1. **embedded_host_config** (`src/embedded_host_config.v`)
   - Pure config parsing, zero `App` dependency
   - Used by `executor_spec.v`, `plugin_runtime.v`

2. **executor_config** (`src/executor_config.v`)
   - PHP worker command builder, env builder
   - Zero `App` dependency

3. **session_handle** (`src/session_handle.v`)
   - Pure data structures + factory functions
   - Zero `App` dependency

4. **transport_handle** (`src/transport_handle.v`)
   - Pure data structures + factory functions
   - Zero `App` dependency

5. **command** (`src/command.v`, `src/command_executor.v`, `src/command_handlers.v`)
   - High-value but deeply coupled to `App` (handlers call `app.codex_*`, `app.feishu_*`)
   - Needs interface extraction before module split

6. **worker_backend** (`src/worker_backend_*.v`)
   - Core infrastructure, but lifecycle methods are `App` methods
   - Needs structural refactoring first

## Phase 3: Memory safety & concurrency (pending)

- Remove `unsafe { nil }` patterns in `admin_server.v`, `codex_runtime.v`,
  `feishu_card_bridge.v`, `inproc_vjsx_executor.v`
- Replace manual mutex chains with `shared` or `chan` where appropriate
- Convert `Mutex` to `RwMutex` for read-heavy admin stats paths

## Phase 4: Observability (pending)

- Prometheus `/admin/metrics` endpoint
- JSON structured log mode (`VHTTPD_LOG_FORMAT=json`)
- Per-module log level control

## Phase 5: Build & distribution (pending)

- Dependency version locking (vjsx, quickjs, V compiler commit pins)
- Dockerfile multi-stage build
- Makefile modularization
