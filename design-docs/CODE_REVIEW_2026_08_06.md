# vhttpd Code Review — 2026-08-06

Snapshot review of the `vhttpd` working tree on `refactor/v2`. Scope: architecture, runtime safety, error handling, observability, CI. Findings are ranked by severity and mapped to the existing `TODO_REFACTOR.md` phases where possible.

---

## 1. Project Snapshot

| Dimension | Value |
|---|---|
| Language / toolchain | V (vlang) + QuickJS (vjsx in-process execution) |
| Entry points | `src/main.v` (veb app), `src/server.v` (process bootstrap) |
| Source files | 478 `.v` — 193 non-test, 63 `*_test.v` (943 test functions, ~36k test lines) |
| Top-level subsystems | admin / relay / worker / feishu / codex / upstream / mcp / openai / websocket / executor / dispatch / db / runtime_plan |
| Docs | `articles/` (14 tutorials), `docs/` (Chinese), `README.md` (70k+) |
| CI | 3 GitHub Actions: build/test/sync-vphp-package |
| Branch | `refactor/v2` (in-progress split) |
| Largest files | `config/config.v` 2434, `admin_server.v` 1027, `feishu/helpers.v` 1103 |

---

## 2. Findings

### 2.1 [HIGH] `App` has become a god object

`src/main.v:16`

```v
pub struct App {
    veb.Middleware[Context]
    veb.StaticHandler
    DataPlaneRuntime   // embeds 13 sub-runtimes
pub mut:
    control_plane ControlPlaneRuntime
    lifecycle     ProcessLifecycle
}
```

`DataPlaneRuntime` (`src/app_composition_runtime.v:14`) hosts 13 sub-runtimes side by side: `transport / websocket / upstreams / relay / protocols / providers / engines / assets / pipelines / transformers / replacement` plus `plan` + `legacy_config`.

Measured coupling:

- **91** non-test files contain `fn (mut app App)` methods.
- **359** total `App` methods in non-test code.
- Top offenders: `admin_runtime.v` (33), `codex_provider_runtime_state.v` (23), `admin_state_runtime.v` (17), `kernel_dispatch.v` (16), `db_runtime_state.v` (13).

`TODO_REFACTOR.md` Phase 2.2 already targets this ("App struct decomposition — not started"). Phase 2.1 still lists 4 candidate modules as blocked:

| Candidate | Coupling | Blocker |
|---|---|---|
| `executor_config` | Zero `App` dep | type deps on `LogicExecutor` in main module |
| `command` | Heavy `App` | handlers call `app.codex_*`, `app.feishu_*` |
| `worker_backend` | Heavy `App` | lifecycle is `App` method |
| `executor family` | Circular | `LogicExecutor` interface takes `mut app App` |

**Why it matters:**

- Unit tests must construct a full `App` to exercise some logic (see 2.2 — this is what already forced the `unsafe` bridge).
- Any field change recompiles the entire binary (V has no incremental link).
- The 16.6 MB binary is largely a symptom of monolith linkage.

**Suggested next step (aligned with Phase 2.2):**

1. Extract an `ExecutorHost` interface so `executor/*` stops depending on `App`.
2. Promote `WorkerState / FeishuState / CodexState / McpState / UpstreamState` from `App` fields to standalone structs held by `&mut`.
3. Tackle `worker_backend` and `command` first — heaviest `App` coupling.

---

### 2.2 [HIGH] `executor_bridge.v` uses `unsafe { voidptr(&app) }` to fake an interface

`src/executor_bridge.v:1-194`

```v
// Wraps App to implement executor.AppFacade without V compiler C codegen bugs
// that occur when App directly implements the interface.
pub struct AppFacadeWrapper {
mut:
    app_ptr voidptr
}

pub fn new_app_facade_wrapper(mut app App) executor.AppFacade {
    return AppFacadeWrapper{ app_ptr: voidptr(&app) }
}

pub fn (w AppFacadeWrapper) get_runtime_config_json() string {
    app := unsafe { &App(w.app_ptr) }   // x20+ in this file
    return app.protocols.runtime_config_json
}
```

The comment explicitly says this is a workaround for a V compiler codegen bug. Every method casts the `voidptr` back to `&App`. **Any V compiler update may turn this into a segfault** — and it directly blocks the modularization goal in 2.1.

**Suggested fix:** replace the wrapper with a real `AppFacade` implementation. Change the interface signatures to take concrete values (e.g. `runtime_config_json string`, `plan_json string`, `read_timeout_ms_for_kind fn(string) int` …) instead of reading through `App` sub-structs. Delete `executor_bridge.v` and the `unsafe` block entirely.

---

### 2.3 [HIGH] Widespread `unsafe { nil }` for shared/global state

`TODO_REFACTOR.md` Phase 3 lists 5 files; the actual count is larger:

```
src/admin_server.v:21             shared &App = unsafe { nil }
src/command_handlers.v:13,111,331 app &App = unsafe { nil }
src/feishu_card_bridge_*.v        5+ unsafe { nil } sites
src/engine_runtime.v:9            emit_fn fn(...) = unsafe { nil }
```

V's `__global`/`shared` cannot initialize structs at compile time, so `nil` placeholders + runtime assignment is a common idiom. But it has real costs:

- Initialization order is implicit — `server.v`'s `ActiveRuntimeRegistry` is `__global`; every `app.shared` depends on the order `register()` is called.
- No startup-time check that the global has been populated.
- Tests can pass `unsafe { nil }` past compile time and only segfault at first deref.

**Suggested fix:**

- Phase 3 first targets: `admin_server.shared &App` and `command_handlers.app` (hot paths).
- For each `unsafe { nil }`, add an invariant comment ("must be called after `app_compose()`"), or refactor to return `Result` so the missing-init case is explicit.
- Long-term: see 2.1 — once subsystems are standalone, the need for shared globals drops.

---

### 2.4 [HIGH] `runtime_trace` hard-codes `/tmp/vhttpd_runtime_trace.log`

`src/main.v:33`

```v
mut f := os.open_append('/tmp/vhttpd_runtime_trace.log') or { return }
```

Three problems:

- No config flag, no way to disable.
- `/tmp` is unwritable on multi-user hosts and many container filesystems.
- Each call opens the file fresh — no lock, slow, racy.

**Suggested fix:** read the path from the same `control.event_log` config that `app_composition_runtime.v:74` uses, and **fail silently only if explicitly disabled** — do not fall back to `/tmp`. See 2.8 (consolidate the two log paths).

---

### 2.5 [MED] Error swallowing: 112 `or { return }` / `or { continue }` sites

Top silent-error sources in non-test code:

- `engine_runtime_builder.v` — 5+ `or { continue }` during route compilation. A failed match silently drops the route.
- `app_composition_runtime.v:74` — `os.open_append(control.event_log) or { return }`. Event-log write failures are invisible to operators.
- `admin_state_runtime.v` — `json.decode(...) or { none }`. Corrupted draft metadata is silently dropped.

**Suggested fix — by phase:**

- **Boot phase** (builder / compile): must `return error(...)` so startup fails loudly.
- **Request hot path** (ingress / dispatch): log + continue, but emit a metric/event.
- **Background tasks** (event_log / provider reconnect): forward to `app.emit('runtime.error', ...)`, queryable through the admin panel.

---

### 2.6 [MED] `time.sleep` in 10 non-test files, including a 15s blocking call

```
src/feishu_card_bridge_client_runtime.v:112  time.sleep(15 * time.second)
src/feishu_provider_connection_runtime.v:31  time.sleep(interval_seconds * time.second)  // reconnect loop
src/feishu_card_bridge_client_runtime.v:161  time.sleep(3 * time.second)
```

V's `time.sleep` blocks the OS thread. A 15s sleep in the WebSocket callback will freeze the connection's handler loop.

**Suggested fix:**

- Replace with `select { <-time.after(...) }` where available, or non-blocking poll loops.
- Break the 15s sleep into 5×3s with ping responsiveness in between.

---

### 2.7 [MED] 8-level lock hierarchy is at the edge of maintainability

`src/server.v:4-24` documents the order L0–L7 explicitly — that documentation is good and should be kept. But:

```
L0  app.mu
L1  app.engines.primary.mu
L2  app.websocket.state.mu
L3  app.websocket.state.upstream_mu
L4  app.protocols.mcp.mu
L5  app.providers.feishu.mu
L6  app.providers.feishu.card_bridge_mu
L7  app.providers.codex.mu
```

plus 3 independent locks (`send_mu` etc.). Every new subsystem risks violating the ordering. The admin stats path under `control_plane.mu` (L0) blocks readers behind writers.

`TODO_REFACTOR.md` Phase 3 already targets `Mutex → RwMutex` for read-heavy admin paths.

**Suggested fix:**

- Switch `admin_state_runtime.v` and `http_stats.v` to `RwMutex` first.
- After the 2.1 split, L0 (`app.mu`) can disappear — subsystem state becomes self-contained.
- Add invariant tests in CI: concurrent N increments to a counter must yield exactly N.

---

### 2.8 [MED] Three parallel logging paths

- `main.v::runtime_trace` → `/tmp/vhttpd_runtime_trace.log` (NDJSON) — see 2.4
- `app_composition_runtime.v::emit` → `control.event_log` (NDJSON)
- `logging/runtime_logger.v` — imported as `log.` in 11 files

Each path has its own format, fields, and filtering. Operators must know the difference between `trace` and `event_log`.

**Suggested fix:** fold `runtime_trace` into `app.emit` (resolves 2.4 at the same time). Use `logging/runtime_logger.v` as the formatter when `VHTTPD_LOG_FORMAT=json`. This is the natural target for `TODO_REFACTOR.md` Phase 4 ("JSON structured log mode").

---

### 2.9 [MED] v1/v2 config dual-track

`src/config/` carries four layers simultaneously:

- `config.v` (v1 TOML, 2434 lines — single largest file in the project)
- `v2_config.v` / `v2_plan_compiler.v` (v2 plan)
- `v1_plan_compat.v` (v1 → v2 compat)
- `runtime_plan_loader.v`

Plus 7 builders in `runtime_plan/`: `protocol_builder / provider_builder / route_builder / resource_builder / runtime_diagnostics / runtime_projection / replacement.v`.

`vhttpd.toml` (the default config) is still v1. Several v1 keys (e.g. `codex.enabled`, `feishu.enabled`) have different semantics in v2.

**Suggested fix:**

- Publish a v1 deprecation timeline (e.g. 6 months) in README.
- Isolate v1 compat under `src/config/compat/`.
- Mark v1-mapped fields with `@[deprecated]` in `v1_plan_compat.v` so they're greppable.

---

### 2.10 [MED] `/tmp` log path is undocumented

`README.md` and `docs/OVERVIEW.md` do not mention `/tmp/vhttpd_runtime_trace.log`. This is a production hazard on multi-user hosts and read-only containers.

**Suggested fix:** add a "Log files and how to disable them" section in `docs/OVERVIEW.md` and link it from README troubleshooting.

---

### 2.11 [LOW] Documentation/code drift

- `TODO_REFACTOR.md` Phase 2.1 claims "✅" for utility module reorganization, but the working tree has active deletions in `.qoder/repowiki/knowledge/zh/...` — likely a knowledge-base migration is in flight.
- `articles/14-future.md` and `TODO_REFACTOR.md` Phase 3-5 should cross-link instead of duplicating plans.

---

### 2.12 [LOW] Test strategy

- 63 test files / 943 test functions — ratio is healthy (~32% of files are tests).
- `inproc_vjsx_executor_codexbot_*_test.v`: 8 files, some 1000+ lines — codexbot integration tests live in one big cluster.
- `server_logic_test.v` (3496 lines), `route_rule_test.v` (675 lines) — single huge test files. Consider splitting into `_test_support.v` + sub-tests.
- `Makefile` excludes `inproc_*` / `db_*` from `test-fast`. `test-inproc` / `test-codexbot` / `test-e2e` are not invoked in `vhttpd-binaries.yml`. `tests/e2e/run.sh` has no matching workflow.

---

### 2.13 [LOW] CI gaps

- No `on: schedule` (no nightly build, no fuzz).
- `Makefile`'s `test-all` is never called in CI.
- `sync-vphp-package.yml` only triggers on `php/package/**` — changes in `php/app/` will not push a new package. Verify this is intentional.

---

### 2.14 [LOW] Stray binaries in repo

`test_bin` (16 MB) and `vhttpd` (16 MB) were committed historically. `.gitignore` excludes `/vhttpd` but not `test_bin` — `git status` does not show them, but they show up after a fresh clone. Add a `clean` target that removes both.

---

### 2.15 [LOW] Chinese directory names in `docs/`

`docs/协议支持`, `docs/API 参考` etc. — cross-platform clone can mangle NFD/NFC normalization on NTFS/HFS+. Not a code issue, but worth a heads-up in the contributing guide.

---

## 3. Things That Are Done Right

1. **Clear architectural direction.** `veb` is the HTTP source of truth; `vhttpd` is the transport / worker / streaming / observability layer; new logic executors (`vjsx`, future `lua`) plug into the unified `LogicExecutor` interface. Documented in README and `articles/10-architecture.md`.
2. **Deep protocol coverage in one binary.** HTTP, WebSocket, SSE, MCP Streamable, OpenAI, Feishu callback, Codex WS — a single binary replaces several gateways.
3. **Observability skeleton.** `admin_runtime` provides `runtime_snapshot / stats_snapshot / plan_replacement`; `control_plane.emit` is a unified event stream.
4. **Test breadth.** 943 test functions, e2e + inproc + unit tests, plus 7 `*_test.php` for the PHP side.
5. **Multi-platform CI.** linux-amd64 / macos-amd64 / macos-arm64.
6. **Lock hierarchy is documented.** `server.v:4-24` is an exemplary "tell future maintainers not to shoot themselves in the foot" comment.
7. **Config examples.** `vhttpd.example.toml / multi.example.toml / vjsx.example.toml` cover the common shapes.
8. **Separated PHP package.** `sync-vphp-package.yml` syncs `php/package` to a dedicated repo — clean single responsibility.

---

## 4. Recommended Next Steps (by ROI)

| # | Action | Expected gain | Effort |
|---|---|---|---|
| 1 | Replace `unsafe { voidptr(&app) }` bridge (2.2) | Removes V-version segfault risk | 2-3 days |
| 2 | Extract `ExecutorHost`, split `worker_backend` / `command` (2.1) | Unlocks modularization for 90 files | 1-2 weeks |
| 3 | Merge `runtime_trace` + `app.emit` (2.4, 2.8) | Simplifies logging, fixes `/tmp` hazard | 0.5 day |
| 4 | Add `tests/e2e/run.sh` and `test-inproc` to CI (2.12, 2.13) | Catch e2e regressions earlier | 0.5 day |
| 5 | Convert `time.sleep` to non-blocking backoff (2.6) | Fix potential connection freezes | 1 day |
| 6 | v1 deprecation doc + `@[deprecated]` markers (2.9, 2.11) | Less user confusion | 0.5 day |

---

## 5. Cross-References

- `TODO_REFACTOR.md` Phase 2.2 — directly covers 2.1.
- `TODO_REFACTOR.md` Phase 3 — covers 2.3 and 2.7.
- `TODO_REFACTOR.md` Phase 4 — covers 2.8.
- `TODO_REFACTOR.md` Phase 5 — Makefile modularization and dependency pinning, not covered here.
- `design-docs/ARCHITECTURE_REFACTOR_BASELINE.md` — earlier architecture read; this review extends it with current-state observations.
