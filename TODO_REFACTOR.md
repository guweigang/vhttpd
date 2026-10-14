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
| 🟡 | command (command.v, command_executor.v, command_handlers.v) | Handlers now require narrow Codex/Feishu/generic command hosts; App adapters remain at assembly boundaries | Nil App defaults and unsafe bridge/mapper App conversions are removed. Provider WebSocket closures use a capability host; Feishu heartbeat uses domain state. V3 build, 7 selected command/provider/OpenAI test files, 6 codexbot-fast files (52 functions), and all 206 E2E checks pass. All 19 command/provider runtime callback defaults now require explicit injection; parent context fields are required as well. Explicit no-op fixtures and lifecycle registration are updated. V3 build, 8 related test files, 3 negative compiler probes, and all 206 E2E checks pass. ProviderSpec now owns the lifecycle context; ProviderRuntimeAdapter only forwards it. Shutdown uses complete specs instead of parallel runtime/context arrays. V3 build, 4 related test files, and all 206 E2E checks pass. Bootstrap now registers a complete spec with one context and retains init/start mutations on success and failure. Final V3 build and 4 related test files pass; isolated provider and SSE scenarios pass against both old and new binaries. Provider probe upgrade-head/deadline handling, per-scenario process cleanup, and repeatable SSE generator construction are fixed with regressions. Complete E2E now passes 207 CLI/config checks plus Node/PHP regressions; full-suite/lifecycle and Linux validation remain pending. |
| 🟡 | worker_backend | Pool/queue/process administration/metrics/backend lifecycle and protocol transport live in `src/worker/`; App adapters remain in `app_worker_backend.v` | EngineRuntime delegates state operations; 5 worker ports and HTTP/WebSocket dispatch core use narrow executor capabilities. V3 build, 12 test files, and 206 E2E checks pass. Registry lookup now uses explicit compatibility policies; embedded internals use the smaller EmbeddedHost through a single polymorphic adapter. 12 selected test files (including 70 inproc executor functions) and 206 E2E checks pass. Request-host access now uses explicit optional lookup with request/lane/executor fallback policies; 9 interface nil placeholders are removed. V3 build, 7 related test files (including 70 inproc executor functions), and all 206 E2E checks pass. Linux/full-suite coverage remains pending. |
| 🔴 | executor family (logic_executor.v, executor_*.v) | `LogicExecutor` interface takes `mut app App` | Circular import blocker. Needs interface extraction. |

### 2.2 App struct decomposition (in progress)

2026-10-14: after establishing V3 compatibility, removed `src/executor_bridge.v` and its `voidptr` casts. `App` directly implements the existing executor capability interfaces in `src/app_executor_facade.v`; facade reads and mutations retain the original App. `make lint-safety` guards this executor boundary before `test-fast`. Subsystem ownership remains in progress; command handlers and provider bridge/mapper paths now use required or optional narrow hosts instead of nil App pointers and unsafe App conversions. StreamRuntimeContext now requires all five callbacks, including open-error rendering. App stream assembly/entry adapters live in app_stream_runtime.v; stream context and execution files have no App dependency. V3 build, 4 related test files, the negative compiler probe, safety lint and 207 E2E checks pass. See the [current action plan](design-docs/REFACTOR_ACTION_PLAN.md) for scope, validation, and next steps.

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
