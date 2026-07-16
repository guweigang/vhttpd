# vhttpd Refactor Tracking

## Phase 2: Modularization (in progress)

### 2.1 Utility module reorganization ✅

| Module | Directory | Files | Status |
|--------|-----------|-------|--------|
| config | `src/config/` | config.v, args.v, embedded_host.v, runtime_config.v | ✅ Merged (common/args.v → config/) |
| transport | `src/transport/` | worker_protocol.v, session_handle.v, transport_handle.v | ✅ Merged (3 modules → 1) |
| state_store | `src/state_store/` | state_store.v, state_store_test.v | ✅ |
| jsonutils | `src/jsonutils/` | json_utils.v, json_utils_test.v | ✅ |

**Changes in this round:**
- `common/args.v` (87 lines) → `config/args.v`: CLI arg parsing is config-adjacent. `module common` deleted.
- `worker_protocol/` + `session_handle/` + `transport_handle/` → `transport/`: All three are worker transport layer types. `session_handle` already imported `worker_protocol`, so consolidation eliminates cross-module imports.
- Module count: 7 → 4 utility modules.

### Transitional type aliases

**transport aliases** → ✅ Cleaned up. 28 `module main` files + main.v itself now use `transport.X` directly. 17 aliases deleted from main.v.

**all state/executor/worker/server_lifecycle aliases** → ✅ Cleaned up (2025-06). All transitional type aliases in `app_states.v`, `executor_lifecycle.v`, `executor_runtime_plan.v`, `worker_backend_runtime.v`, `server_runtime_config.v`, `multi_server_runtime_config.v` replaced with fully-qualified names (`module.TypeName`). 8 files deleted. `executor_config.v` deleted. `executor_registry.v` retains only the `admin_logic_executor_specs_snapshot()` App method.

**config aliases** → still pending. 27 config type aliases remain in main.v (`pub type VhttpdConfig = config.VhttpdConfig` etc.). These should be cleaned up once all callers use `config.X` directly.

### Plugin module consolidation

**plugin/ + plugins/** → ✅ Merged (2025-06). `plugins/` (plural) deleted; `PluginState` moved to `plugin/types.v` alongside the runtime builder functions. All callers updated from `plugins.PluginState` to `plugin.PluginState`.

### 2.1 Remaining: domain module extraction

| Priority | Candidate | Coupling | Notes |
|----------|-----------|----------|-------|
| 🟡 | executor_config | Zero `App` dependency | PHP worker command/env builder. Blocked by type deps on LogicExecutor/LogicExecutorLifecycle in main module. |
| 🔴 | command (command.v, command_executor.v, command_handlers.v) | Heavily coupled to `App` | Handlers call `app.codex_*`, `app.feishu_*`. Needs ExecutorHost interface extraction first. |
| 🔴 | worker_backend (worker_backend_*.v) | Lifecycle methods are `App` methods | Core infrastructure. Needs App struct decomposition first. |
| 🔴 | executor family (logic_executor.v, executor_*.v) | `LogicExecutor` interface takes `mut app App` | Circular import blocker. Needs interface extraction. |

### 2.2 App struct decomposition (not started)

Per the roadmap, after domain modules are extracted:
- Extract subsystem state from `App` into independent structs (`WorkerState`, `FeishuState`, etc.)
- Define `ExecutorHost` context interface to break circular dep
- Provider bootstrap → iterate `app.providers` list

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
